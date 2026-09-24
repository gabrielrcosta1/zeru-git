import Foundation

/// A git failure translated into something a person can act on.
struct GitProblem {
    var message: String
    var hint: String?
    var command: String?
    var isLockContention = false
    var raw: String = ""

    var full: String {
        var text = message
        if let hint { text += "\n" + hint }
        return text
    }
}

enum GitFailure {

    static func isLockContention(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        if lower.contains("index.lock") { return true }
        if lower.contains("another git process seems to be running") { return true }
        return false
    }

    /// git prints the absolute path it could not create:
    /// fatal: Unable to create '<path>.lock': File exists.
    static func lockPath(in stderr: String) -> String? {
        guard let open = stderr.range(of: "Unable to create '") else { return nil }
        let rest = stderr[open.upperBound...]
        guard let close = rest.range(of: "'") else { return nil }
        let path = String(rest[..<close.lowerBound])
        return path.hasSuffix(".lock") ? path : nil
    }

    /// True when git refused because files that are not in its history would
    /// be written over. Nothing is wrong with the repository: the files are
    /// simply in the way, and moving them aside is the whole fix.
    ///
    /// Two wordings, both verified against git: "The following untracked
    /// working tree files would be overwritten by checkout" for a file, and
    /// "Updating the following directories would lose untracked files in them"
    /// when the local path is a directory.
    static func isUntrackedBlock(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        if lower.contains("would lose untracked files") { return true }
        guard lower.contains("would be overwritten") else { return false }
        return lower.contains("untracked working tree file")
    }

    /// The paths git listed as being in the way, and only the untracked ones.
    ///
    /// git prints them one per line, tab-indented, under a header that says
    /// which kind they are, and it can print BOTH lists in one go: taking
    /// every tab line would call a tracked, modified file "not in git".
    static func blockedPaths(in stderr: String) -> [String] {
        var paths: [String] = []
        var collecting = false
        for line in stderr.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("\t") {
                guard collecting else { continue }
                let path = String(line.drop(while: { $0 == "\t" || $0 == " " }))
                    .trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty, !paths.contains(path) else { continue }
                paths.append(path)
                continue
            }
            let lower = line.lowercased()
            collecting = lower.contains("untracked working tree file")
                || lower.contains("would lose untracked files")
        }
        return paths
    }

    /// Maps the raw output of git onto a message, and where possible the one
    /// command the user can run to get out of it.
    static func describe(_ error: Error) -> GitProblem {
        guard let shellError = error as? ShellError else {
            return GitProblem(message: error.localizedDescription)
        }

        switch shellError {
        case .notFound:
            return GitProblem(message: "git was not found on this Mac.",
                              hint: "Install the Xcode command line tools: xcode-select --install")

        case .failed(let command, let status, let stderr):
            let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = text.lowercased()
            var problem = GitProblem(message: "", command: command, raw: text)

            if isLockContention(text) {
                problem.message = "Another process is using this repository's index."
                problem.hint = "Git Agent retried a few times. Close other git clients, or remove the stale lock file."
                problem.isLockContention = true
                return problem
            }

            if lower.contains("not a git repository") {
                problem.message = "This folder is not a git repository any more."
                return problem
            }
            if lower.contains("nothing to commit") || lower.contains("no changes added to commit") {
                problem.message = "There is nothing selected to commit."
                problem.hint = "Tick the files you want to include, or turn on \"Stage all changes when committing\" in Settings."
                return problem
            }
            if lower.contains("please tell me who you are") || lower.contains("unable to auto-detect email") {
                problem.message = "Git does not know who you are yet."
                problem.hint = "git config --global user.name \"Your Name\" && git config --global user.email \"you@example.com\""
                return problem
            }
            if lower.contains("authentication failed") || lower.contains("could not read username")
                || lower.contains("permission denied (publickey)") || lower.contains("host key verification failed")
                || lower.contains("terminal prompts disabled") {
                problem.message = "Git could not authenticate with the remote."
                problem.hint = "Push once from your terminal so the credentials or SSH key are set up, then try again here."
                return problem
            }
            if lower.contains("non-fast-forward") || lower.contains("updates were rejected")
                || lower.contains("fetch first") {
                problem.message = "The remote has commits that you do not have."
                problem.hint = "Sync & Pull brings them in and keeps your uncommitted work. Git Agent never force pushes."
                return problem
            }
            if lower.contains("hook") && (lower.contains("declined") || lower.contains("failed") || lower.contains("exit")) {
                problem.message = "A git hook rejected this operation."
                problem.hint = firstLines(text, 4)
                return problem
            }
            if lower.contains("cannot pull with rebase") || lower.contains("cannot rebase")
                || (lower.contains("unstaged changes") && lower.contains("pull")) {
                problem.message = "Pull needs a clean working tree."
                problem.hint = "Commit or stash your changes first (\u{22ef} \u{2192} Stash changes), then pull again."
                return problem
            }
            // "already exists" on its own also matches a conflicted stash
            // pop ("u.txt already exists, no checkout"), and calling that a
            // branch name clash sends the user somewhere useless.
            if lower.contains("already exists") && lower.contains("branch") {
                problem.message = "That branch already exists."
                problem.hint = "Pick it from the branch list instead, or choose another name."
                return problem
            }
            if lower.contains("no stash entries") {
                problem.message = "There is nothing in the stash."
                return problem
            }
            if lower.contains("unmerged") || lower.contains("you have unmerged paths") {
                problem.message = "There are unresolved conflicts."
                problem.hint = "Resolve them, mark the files as resolved, then commit."
                return problem
            }
            if lower.contains("did not match any file") || lower.contains("pathspec") {
                problem.message = "Git no longer knows one of these paths."
                problem.hint = "The working tree changed underneath. Refresh and try again."
                return problem
            }
            if lower.contains("no upstream") || lower.contains("has no upstream branch") {
                problem.message = "This branch has no upstream yet."
                problem.hint = "Use Commit & Push and Git Agent will create it on origin."
                return problem
            }
            if lower.contains("would be overwritten") || lower.contains("local changes") {
                problem.message = "This would overwrite local changes."
                problem.hint = firstLines(text, 3)
                return problem
            }
            if lower.contains("could not resolve host") || lower.contains("network is unreachable")
                || lower.contains("operation timed out") {
                problem.message = "The remote could not be reached."
                problem.hint = "Check your connection and try again."
                return problem
            }

            if status == 15 || status == 143 {
                problem.message = "\(command) took too long and was stopped."
                if command.contains("push") || command.contains("fetch") {
                    problem.hint = "It may be waiting for your git credentials. Run it once in your terminal so they get stored, then try again here."
                } else if command.contains("commit") {
                    problem.hint = "A pre-commit hook is probably still running. Run the commit once in your terminal to see what it is waiting for."
                } else {
                    problem.hint = "Check your connection and try again."
                }
                return problem
            }

            problem.message = text.isEmpty ? "git \(command) failed." : firstLines(text, 3)
            return problem
        }
    }

    private static func firstLines(_ text: String, _ count: Int) -> String {
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(count)
            .joined(separator: "\n")
    }
}

/// Who has the lock file open. A name beats "something".
struct LockHolder: Identifiable {
    let pid: Int32
    let name: String
    /// True when this is a process Git Agent started, or one started by it
    /// (a pre-commit hook, for instance).
    let ours: Bool

    var id: Int32 { return pid }
    var label: String { return "\(name) (pid \(pid))" }

    /// Virtualization and file sharing processes. A VM with this folder
    /// mounted keeps a descriptor on the file on behalf of whatever ran
    /// inside it: it is not a git client, it never releases the file on its
    /// own, and it cannot be closed from here. Counting it as the owner of
    /// the lock leaves the dialog with no way out, so it does not count.
    static let proxyNames: Set<String> = [
        "com.apple.Virtualization.VirtualMachine",
        "VirtualMachine",
        "virtiofsd",
        "com.docker.virtualization",
        "vfkit"
    ]

    var isProxy: Bool { return !ours && LockHolder.proxyNames.contains(name) }
}

/// What the app knows about a lock file that is in the way.
struct GitLockInfo {
    let path: String
    let age: TimeInterval
    let holders: [LockHolder]
    /// False when lsof could not be consulted: then "no holders" means
    /// "unknown", and nothing may be removed on that basis.
    let probed: Bool

    /// Processes that can actually be holding a git operation open.
    var realHolders: [LockHolder] { return holders.filter { !$0.isProxy } }
    /// File sharing proxies: seen, reported, but never the owner.
    var proxyHolders: [LockHolder] { return holders.filter { $0.isProxy } }

    var isHeld: Bool { return !realHolders.isEmpty }
    var ourHolders: [LockHolder] { return holders.filter { $0.ours } }
    var heldByUs: Bool { return !ourHolders.isEmpty }

    var ageText: String {
        if age < 60 { return "\(Int(age)) seconds old" }
        if age < 3600 { return "\(Int(age / 60)) minutes old" }
        return "\(Int(age / 3600)) hours old"
    }

    /// Nobody that matters holds it and it has been sitting there: safe to
    /// remove. A lock only a VM has open needs to be older, because a git
    /// command running inside that VM is a real possibility for a while.
    var looksStale: Bool {
        guard probed, realHolders.isEmpty else { return false }
        return proxyHolders.isEmpty ? age > 10 : age > 120
    }

    private var names: String {
        return realHolders.map { $0.label }.joined(separator: ", ")
    }

    /// One paragraph that says exactly what is going on.
    var explanation: String {
        if realHolders.isEmpty {
            if !probed {
                return "Git Agent could not check which process has it open, so it will not remove it. Close other git clients and try again."
            }
            if proxyHolders.isEmpty {
                return "Nothing has it open, so a git command left it behind when it crashed. Removing it is safe."
            }
            let list = proxyHolders.map { $0.label }.joined(separator: ", ")
            if looksStale {
                return "Only \(list) has it open: a virtual machine that shares this folder, not a git client. It holds the file for whatever ran inside it and will not release it on its own. If no git command is running in that VM, removing the lock is safe."
            }
            return "\(list) has it open: a virtual machine that shares this folder. A git command inside it may still be running, so wait a few seconds and try again."
        }
        if heldByUs && ourHolders.count == realHolders.count {
            let list = ourHolders.map { $0.label }.joined(separator: ", ")
            return "This is Git Agent's own command still running: \(list). A pre-commit hook is the usual reason. Stopping it is safe \u{2014} the operation simply will not happen."
        }
        return "\(names) has it open. Close that app or wait for it to finish: Git Agent will not remove a lock that something else is holding."
    }
}
