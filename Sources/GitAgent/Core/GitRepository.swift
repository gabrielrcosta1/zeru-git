import Foundation

/// Thin, read-mostly wrapper around the `git` command line.
/// Every mutating operation is explicit and non destructive:
/// no reset --hard, no clean, no rebase, no force push.
struct GitRepository {
    let root: URL

    /// Every invocation goes through this actor, one at a time.
    private let runner: GitRunner

    init(root: URL) {
        self.root = root
        self.runner = GitRunner(root: root)
    }

    // MARK: - Discovery

    static func discoverRoot(from url: URL) async -> URL? {
        guard let result = try? await Shell.run("git", ["rev-parse", "--show-toplevel"], cwd: url) else { return nil }
        guard result.ok else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - Plumbing

    @discardableResult
    private func git(_ arguments: [String], timeout: TimeInterval? = nil) async throws -> CommandResult {
        return try await runner.run(arguments, timeout: timeout)
    }

    @discardableResult
    private func gitOK(_ arguments: [String], timeout: TimeInterval? = nil) async throws -> String {
        let result = try await git(arguments, timeout: timeout)
        guard result.ok else {
            throw ShellError.failed(command: "git " + arguments.joined(separator: " "),
                                    status: result.status,
                                    stderr: result.stderr)
        }
        return result.stdout
    }

    // MARK: - State

    func state() async throws -> RepoState {
        var state = RepoState(root: root)

        let raw = try await gitOK(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"])
        let entries = raw.components(separatedBy: "\0")
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            index += 1
            if entry.isEmpty { continue }

            if entry.hasPrefix("# ") {
                apply(header: entry, to: &state)
                continue
            }

            switch entry.first {
            case "1":
                let fields = split(entry, maxSplits: 8)
                guard fields.count == 9, let codes = statusCodes(fields[1]) else { continue }
                state.changes.append(makeChange(path: fields[8],
                                                original: nil,
                                                staged: codes.0,
                                                worktree: codes.1,
                                                forceRenamed: false))
            case "2":
                let fields = split(entry, maxSplits: 9)
                guard fields.count == 10, let codes = statusCodes(fields[1]) else { continue }
                var original: String?
                if index < entries.count, !entries[index].isEmpty {
                    original = entries[index]
                    index += 1
                }
                state.changes.append(makeChange(path: fields[9],
                                                original: original,
                                                staged: codes.0,
                                                worktree: codes.1,
                                                forceRenamed: true))
            case "u":
                let fields = split(entry, maxSplits: 10)
                guard fields.count == 11 else { continue }
                state.changes.append(FileChange(path: fields[10],
                                                originalPath: nil,
                                                status: .conflict,
                                                staged: false,
                                                unstaged: true))
            case "?":
                let path = String(entry.dropFirst(2))
                guard !path.isEmpty else { continue }
                state.changes.append(FileChange(path: path,
                                                originalPath: nil,
                                                status: .untracked,
                                                staged: false,
                                                unstaged: true))
            default:
                continue
            }
        }

        await applyLineCounts(to: &state)
        await applyProgressFlags(to: &state)
        state.recentCommits = await recentCommits(limit: 12)
        state.changes.sort { lhs, rhs in
            if lhs.status == .conflict && rhs.status != .conflict { return true }
            if rhs.status == .conflict && lhs.status != .conflict { return false }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
        return state
    }

    private func apply(header entry: String, to state: inout RepoState) {
        let parts = entry.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3 else { return }
        switch parts[1] {
        case "branch.head":
            if parts[2] == "(detached)" {
                state.detached = true
            } else {
                state.branch = parts[2]
            }
        case "branch.upstream":
            state.upstream = parts[2]
        case "branch.ab":
            for token in parts[2].split(separator: " ") {
                if token.hasPrefix("+") { state.ahead = Int(token.dropFirst()) ?? 0 }
                if token.hasPrefix("-") { state.behind = Int(token.dropFirst()) ?? 0 }
            }
        default:
            break
        }
    }

    private func split(_ entry: String, maxSplits: Int) -> [String] {
        return entry.split(separator: " ", maxSplits: maxSplits, omittingEmptySubsequences: false).map(String.init)
    }

    private func statusCodes(_ field: String) -> (Character, Character)? {
        let characters = Array(field)
        guard characters.count >= 2 else { return nil }
        return (characters[0], characters[1])
    }

    private func makeChange(path: String,
                            original: String?,
                            staged: Character,
                            worktree: Character,
                            forceRenamed: Bool) -> FileChange {
        let isStaged = staged != "."
        let isUnstaged = worktree != "."
        var status: FileStatus
        if forceRenamed {
            status = .renamed
        } else if isUnstaged {
            status = FileStatus.from(code: worktree)
        } else {
            status = FileStatus.from(code: staged)
        }
        return FileChange(path: path,
                          originalPath: original,
                          status: status,
                          staged: isStaged,
                          unstaged: isUnstaged)
    }

    private func applyProgressFlags(to state: inout RepoState) async {
        guard let gitDir = await gitDirectory() else { return }
        let fm = FileManager.default
        state.isMerging = fm.fileExists(atPath: gitDir.appendingPathComponent("MERGE_HEAD").path)
        state.isRebasing = fm.fileExists(atPath: gitDir.appendingPathComponent("rebase-merge").path)
            || fm.fileExists(atPath: gitDir.appendingPathComponent("rebase-apply").path)
    }

    // MARK: - Locks

    func gitDirectory() async -> URL? {
        return await runner.gitDirectory()
    }

    /// Reports the lock file that is in the way. `path` comes from git's own
    /// error message when it is available, otherwise the index lock is assumed.
    func lockInfo(at path: String? = nil) async -> GitLockInfo? {
        var lock: URL
        if let path, path.hasSuffix(".lock") {
            lock = URL(fileURLWithPath: path)
        } else {
            guard let gitDir = await gitDirectory() else { return nil }
            lock = gitDir.appendingPathComponent("index.lock")
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: lock.path) else { return nil }
        let modified = (attributes[.modificationDate] as? Date) ?? Date()
        let found = await GitRepository.holders(of: lock.path)
        return GitLockInfo(path: lock.path,
                           age: max(0, Date().timeIntervalSince(modified)),
                           holders: found ?? [],
                           probed: found != nil)
    }

    /// Deletes one lock file inside this repository's git directory, and nothing
    /// else. Only ever called after the user confirms it in a dialog.
    func removeLock(at path: String) async throws {
        guard let gitDir = await gitDirectory() else { throw GitError.notARepository(root.path) }
        let lock = URL(fileURLWithPath: path).standardizedFileURL
        let expected = gitDir.standardizedFileURL.path
        guard lock.pathExtension == "lock", lock.path.hasPrefix(expected + "/") else { return }
        guard FileManager.default.fileExists(atPath: lock.path) else { return }
        try FileManager.default.removeItem(at: lock)
    }

    /// Which processes have that file open, by name. `-w` silences the warnings
    /// lsof prints for other volumes and `-Fp` prints one "p<pid>" per line, so
    /// a warning can never be mistaken for a holder.
    ///
    /// Returns nil when the check itself could not be made: an empty list has
    /// to mean "nobody", never "I could not tell".
    static func holders(of path: String) async -> [LockHolder]? {
        guard let result = try? await Shell.run("lsof", ["-w", "-Fp", path], cwd: nil, timeout: 8),
              result.status == 0 || result.status == 1 else { return nil }

        var pids: [Int32] = []
        for line in result.stdout.split(separator: "\n") {
            guard line.hasPrefix("p"), let pid = Int32(line.dropFirst()) else { continue }
            pids.append(pid)
        }
        guard !pids.isEmpty else { return [] }

        var names: [Int32: String] = [:]
        let list = pids.map(String.init).joined(separator: ",")
        if let ps = try? await Shell.run("ps", ["-o", "pid=,comm=", "-p", list], cwd: nil, timeout: 8) {
            for line in ps.stdout.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
                let command = String(parts[1]).trimmingCharacters(in: .whitespaces)
                names[pid] = (command as NSString).lastPathComponent
            }
        }

        let cache = ParentCache()
        var holders: [LockHolder] = []
        for pid in pids {
            holders.append(LockHolder(pid: pid,
                                      name: names[pid] ?? "process",
                                      ours: await isDescendantOfApp(pid, cache: cache)))
        }
        return holders
    }

    /// A hook started by our own git is still our responsibility, so walk up.
    private static func isDescendantOfApp(_ pid: Int32, cache: ParentCache = ParentCache()) async -> Bool {
        let mine = ProcessInfo.processInfo.processIdentifier
        var current = pid
        for _ in 0..<12 {
            if current == mine { return true }
            if ProcessRegistry.shared.contains(current) { return true }
            if let known = cache.parents[current] {
                current = known
                continue
            }
            guard let result = try? await Shell.run("ps", ["-o", "ppid=", "-p", "\(current)"],
                                                    cwd: nil, timeout: 5),
                  let parent = Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
                  parent > 1 else { return false }
            cache.parents[current] = parent
            current = parent
        }
        return false
    }

    /// Sends SIGTERM to processes the app itself started. Never to anything else.
    static func stop(_ pids: [Int32]) async {
        let cache = ParentCache()
        for pid in pids {
            guard await isDescendantOfApp(pid, cache: cache) else { continue }
            _ = kill(pid, SIGTERM)
        }
    }

    // MARK: - Line counts

    private func applyLineCounts(to state: inout RepoState) async {
        var counts: [String: (Int, Int)] = [:]
        for staged in [false, true] {
            for (path, value) in await numstat(staged: staged) {
                let current = counts[path] ?? (0, 0)
                counts[path] = (current.0 + value.0, current.1 + value.1)
            }
        }
        for offset in state.changes.indices {
            let change = state.changes[offset]
            if let value = counts[change.path] {
                state.changes[offset].additions = value.0
                state.changes[offset].deletions = value.1
            } else if change.status == .untracked {
                state.changes[offset].additions = lineCount(of: change.path)
            }
        }
    }

    private func numstat(staged: Bool) async -> [String: (Int, Int)] {
        var arguments = ["diff", "--numstat", "--no-color"]
        if staged { arguments.append("--cached") }
        guard let output = try? await gitOK(arguments) else { return [:] }
        var result: [String: (Int, Int)] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { continue }
            let additions = Int(fields[0]) ?? 0
            let deletions = Int(fields[1]) ?? 0
            var path = fields[2]
            // Renames appear as "old => new" or "dir/{old => new}/file".
            if let open = path.range(of: "{"), let close = path.range(of: "}"),
               let arrow = path.range(of: " => ", range: open.upperBound..<close.lowerBound) {
                path = String(path[..<open.lowerBound])
                    + path[arrow.upperBound..<close.lowerBound]
                    + path[close.upperBound...]
            } else if let arrow = path.range(of: " => ") {
                path = String(path[arrow.upperBound...])
            }
            result[path] = (additions, deletions)
        }
        return result
    }

    private func lineCount(of relativePath: String) -> Int {
        let url = root.appendingPathComponent(relativePath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size <= 2_000_000 else { return 0 }
        guard let data = try? Data(contentsOf: url) else { return 0 }
        if data.prefix(8000).contains(0) { return 0 }
        var count = data.reduce(into: 0) { partial, byte in
            if byte == 0x0A { partial += 1 }
        }
        if let last = data.last, last != 0x0A { count += 1 }
        return count
    }

    // MARK: - Diffs

    func diff(for change: FileChange, contextLines: Int = 3) async -> String {
        let context = ["-U\(contextLines)", "--no-color"]
        switch change.status {
        case .untracked:
            let absolute = root.appendingPathComponent(change.path).path
            let result = try? await git(["diff", "--no-index"] + context + ["--", "/dev/null", absolute])
            return result?.stdout ?? ""
        case .conflict:
            let result = try? await git(["diff"] + context + ["--", change.path])
            return result?.stdout ?? ""
        default:
            var arguments = ["diff"] + context
            if change.staged && !change.unstaged { arguments.append("--cached") }
            arguments.append(contentsOf: ["-M", "--", change.path])
            if let original = change.originalPath { arguments.append(original) }
            let result = try? await git(arguments)
            return result?.stdout ?? ""
        }
    }

    /// Combined diff of every tracked change, used for AI context and the
    /// "All changes" view.
    func combinedDiff(contextLines: Int = 3, excluding excluded: [String] = []) async -> String {
        let context = ["-U\(contextLines)", "--no-color", "-M"]
        var pathspec: [String] = ["--"]
        pathspec.append(contentsOf: excluded.map { ":(exclude)\($0)" })
        let unstaged = (try? await git(["diff"] + context + (excluded.isEmpty ? [] : pathspec)))?.stdout ?? ""
        let staged = (try? await git(["diff", "--cached"] + context + (excluded.isEmpty ? [] : pathspec)))?.stdout ?? ""
        var parts: [String] = []
        if !staged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("# staged changes\n" + staged)
        }
        if !unstaged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("# unstaged changes\n" + unstaged)
        }
        return parts.joined(separator: "\n")
    }

    func conflictSide(_ stage: Int, path: String) async -> String? {
        guard let result = try? await git(["show", ":\(stage):\(path)"]), result.ok else { return nil }
        return result.stdout
    }

    // MARK: - Fetch

    /// Updates the remote tracking refs so the app knows how far behind the
    /// branch is. It never touches the index, the working tree or a local
    /// branch, but it does write FETCH_HEAD and the remote-tracking refs, so
    /// it takes its turn in the queue like everything else: a fetch landing in
    /// the middle of a pull is two commands writing the same refs.
    func fetch() async throws {
        let result = try await runner.runNetwork(["fetch", "--quiet", "origin"], timeout: 25)
        guard result.ok else {
            throw ShellError.failed(command: "fetch origin",
                                    status: result.status,
                                    stderr: result.stderr)
        }
    }

    // MARK: - History

    /// The commit HEAD is on. Nil in a repository with no commit yet.
    func head() async -> String? {
        guard let result = try? await git(["rev-parse", "HEAD"]), result.ok else { return nil }
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    func recentCommits(limit: Int) async -> [GitCommit] {
        let format = "%H%x1f%s%x1f%an%x1f%ar"
        guard let output = try? await gitOK(["log", "-n", "\(limit)", "--pretty=format:\(format)"]) else { return [] }
        var commits: [GitCommit] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4 else { continue }
            commits.append(GitCommit(sha: fields[0], subject: fields[1], author: fields[2], relativeDate: fields[3]))
        }
        return commits
    }

    func show(commit sha: String) async -> String {
        guard let result = try? await git(["show", "--no-color", "--stat", "--patch", "-M", sha]) else { return "" }
        return result.stdout
    }

    // MARK: - Workflow steps

    /// Runs one step of a workflow.
    ///
    /// The argv comes from a fixed template in `WorkflowExpander`, and the only
    /// thing the user supplies is a name that was checked against
    /// `isSafeName` first, so nothing here is ever a string someone typed as a
    /// command. It goes through the ordinary queue, network steps included:
    /// a workflow is an ordered thing, and the separate network queue would
    /// let a push overtake the checkout that has to come first.
    func runStep(_ arguments: [String], timeout: TimeInterval) async throws -> String {
        let result = try await runner.run(arguments, timeout: timeout)
        guard result.ok else {
            throw ShellError.failed(command: arguments.joined(separator: " "),
                                    status: result.status,
                                    stderr: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result.stdout + result.stderr
    }

    // MARK: - Synchronising

    /// One command of the sync flow, with its whole result.
    ///
    /// The sync needs to tell "stopped on a conflict" from "failed" from
    /// "there was nothing to do", and all three come back as a non-zero exit
    /// with different text. Throwing here would flatten them.
    func syncRun(_ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        return try await runner.run(arguments, timeout: timeout)
    }

    /// What this app is running against this repository right now, if anything.
    func currentActivity() async -> (command: String, waiting: Int)? {
        return await runner.activity
    }

    /// The upstream of the current branch, as git resolves it: "origin/main".
    /// Nil when the branch tracks nothing, which is not an error.
    func upstreamRef() async -> String? {
        guard let result = try? await runner.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]),
              result.ok else { return nil }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// How far apart HEAD and the given ref are, counted fresh.
    func distance(to ref: String) async -> (ahead: Int, behind: Int)? {
        guard let result = try? await runner.run(["rev-list", "--left-right", "--count", "HEAD...\(ref)", "--"]),
              result.ok else { return nil }
        let parts = result.stdout.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
        guard parts.count >= 2, let ahead = Int(parts[0]), let behind = Int(parts[1]) else { return nil }
        return (ahead, behind)
    }

    /// The stash entry this app just made, found by the exact message it wrote.
    /// Resolved by sha the moment it is needed, because stash@{N} renumbers.
    func stashRef(withMessage message: String) async -> String? {
        guard let entries = await stashes() else { return nil }
        guard let match = entries.first(where: { $0.subject.contains(message) }) else { return nil }
        return match.ref
    }

    // MARK: - Running an approved command

    /// Runs a command the policy has already approved.
    ///
    /// The policy is the gate; this refuses to be a second, weaker one. It
    /// takes the verdict rather than the command so a caller cannot run
    /// something without a verdict existing for it.
    func runAllowed(_ arguments: [String], risk: GitCommandRisk) async throws -> String {
        guard risk.isRunnable else {
            throw GitError.commandRefused("git " + arguments.joined(separator: " "))
        }
        let result = try await runner.run(arguments, timeout: 180)
        guard result.ok else {
            throw ShellError.failed(command: arguments.joined(separator: " "),
                                    status: result.status,
                                    stderr: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result.stdout + result.stderr
    }

    // MARK: - Interactive rebase

    /// The commits that can be rewritten without a force push, oldest first —
    /// git's own todo order.
    ///
    /// With an upstream that is the boundary: anything already published is off
    /// limits. Without one, nothing has been published, so the last commits are
    /// all fair game.
    func rebasableCommits(upstream: String?, limit: Int) async -> [CommitNode] {
        let format = "%H%x1f%s%x1f%an%x1f%ar%x1f%P"
        var arguments = ["log", "--reverse", "-n", "\(limit)", "--pretty=format:\(format)"]
        let clean = upstream?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        arguments.append(clean.isEmpty ? "HEAD" : clean + "..HEAD")
        arguments.append("--")
        guard let result = try? await git(arguments, timeout: 20), result.ok else { return [] }

        var nodes: [CommitNode] = []
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, !fields[0].isEmpty else { continue }
            let parents = fields.count > 4
                ? fields[4].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                : []
            nodes.append(CommitNode(commit: GitCommit(sha: fields[0],
                                                      subject: fields[1],
                                                      author: fields[2],
                                                      relativeDate: fields[3]),
                                    parents: parents))
        }
        return nodes
    }

    /// Replays a sequence with a todo list the app wrote.
    ///
    /// `GIT_SEQUENCE_EDITOR` is how the plan gets in: git runs it with the path
    /// of its own todo file, and `cp` overwrites that file with ours.
    /// `GIT_EDITOR` stays `true` so nothing can ever sit waiting for an editor
    /// — every message the plan changes is applied by an
    /// `exec git commit --amend --file=…` line instead.
    func runInteractiveRebase(base: RebaseBase, todo: URL) async throws -> String {
        let editor = "cp " + GitRepository.singleQuoted(todo.path)
        var arguments = ["rebase", "--interactive", "--no-autosquash"]
        arguments.append(contentsOf: base.arguments)
        let result = try await runner.run(arguments,
                                          env: ["GIT_SEQUENCE_EDITOR": editor, "GIT_EDITOR": "true"],
                                          timeout: 600)
        guard result.ok else {
            throw ShellError.failed(command: "rebase --interactive",
                                    status: result.status,
                                    stderr: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result.stdout + result.stderr
    }

    /// git hands the value of GIT_SEQUENCE_EDITOR to a shell, so a path with a
    /// space in it has to survive that.
    static func singleQuoted(_ path: String) -> String {
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Remote

    /// The push URL of origin, as configured. Nil when there is no origin.
    func remoteURL() async -> String? {
        guard let result = try? await git(["remote", "get-url", "origin"]), result.ok else { return nil }
        let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    // MARK: - Search

    /// One record per commit, NUL terminated, because the body it carries can
    /// contain newlines. \u{1f} separates the fields inside a record.
    private static let searchFormat = "%H%x1f%s%x1f%an%x1f%ar%x1f%b%x00"

    /// Commits from every ref, filtered by git itself.
    ///
    /// Each word of the query becomes its own `--grep` and `--all-match` ties
    /// them together, so word order does not matter — the same rule the
    /// in-memory matching uses. `--fixed-strings` so a query with regex
    /// characters in it means exactly what it says, and `-i` so case never has
    /// to be guessed.
    func searchCommits(text: String, author: String?, limit: Int) async -> [CommitMatch] {
        let cleanAuthor = author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let words = SearchMatch.words(text)
        guard !words.isEmpty || !cleanAuthor.isEmpty else { return [] }

        var arguments = ["log", "--all", "--date-order",
                         "--fixed-strings", "--regexp-ignore-case",
                         "-n", "\(limit)",
                         "--pretty=format:\(GitRepository.searchFormat)"]
        if !words.isEmpty {
            if words.count > 1 { arguments.append("--all-match") }
            for word in words { arguments.append("--grep=" + word) }
        }
        if !cleanAuthor.isEmpty { arguments.append("--author=" + cleanAuthor) }
        guard let result = try? await git(arguments, timeout: 20), result.ok else { return [] }
        return GitRepository.parseMatches(result.stdout)
    }

    /// A commit named directly by a sha prefix, when the query looks like one.
    ///
    /// The prefix is resolved to a commit first, and the sha is then passed with
    /// a `--` terminator. `git log <arg>` on its own is ambiguous between a
    /// revision and a path, so a repository with a file called "deadbeef" would
    /// otherwise answer with the last commit that touched that file.
    func commit(withPrefix prefix: String) async -> CommitMatch? {
        guard prefix.count >= 4, prefix.count <= 40,
              prefix.allSatisfy({ $0.isHexDigit }) else { return nil }
        guard let sha = await resolve(prefix) else { return nil }
        guard let result = try? await git(["log", "-n", "1",
                                           "--pretty=format:\(GitRepository.searchFormat)",
                                           sha, "--"], timeout: 15),
              result.ok else { return nil }
        return GitRepository.parseMatches(result.stdout).first
    }

    /// Every tracked path. `-z` because a path is allowed to contain a newline.
    /// Returns nil when the read failed, so an empty list always means an empty
    /// repository.
    func trackedFiles(limit: Int) async -> [String]? {
        guard let result = try? await git(["ls-files", "-z"], timeout: 30), result.ok else { return nil }
        var paths: [String] = []
        for path in result.stdout.components(separatedBy: "\0") where !path.isEmpty {
            paths.append(path)
            if paths.count >= limit { break }
        }
        return paths
    }

    private static func parseMatches(_ output: String) -> [CommitMatch] {
        var matches: [CommitMatch] = []
        for record in output.components(separatedBy: "\0") {
            // `format:` puts a newline between records, which lands at the
            // front of every record after the first.
            let clean = record.drop(while: { $0 == "\n" || $0 == "\r" })
            guard !clean.isEmpty else { continue }
            let fields = clean.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, !fields[0].isEmpty else { continue }
            let commit = GitCommit(sha: fields[0],
                                   subject: fields[1],
                                   author: fields[2],
                                   relativeDate: fields[3])
            matches.append(CommitMatch(commit: commit, body: fields.count > 4 ? fields[4] : ""))
        }
        return matches
    }

    // MARK: - Reflog and recovery

    /// Every recorded position of one branch's tip, newest first.
    ///
    /// Read straight from `logs/refs/heads/<branch>` instead of through
    /// `git reflog`, because the file carries the value the ref had **before**
    /// each move. `git reflog` only reports the value after, so the previous
    /// one has to be guessed from the next line — and that guess is wrong once
    /// `git gc` has expired an entry in the middle.
    ///
    /// Returns nil when the read failed. A branch with no reflog yet is an
    /// empty list, which is not the same thing.
    func branchReflog(branch: String, limit: Int) async -> [ReflogEntry]? {
        guard !branch.isEmpty, let gitDir = await gitDirectory() else { return nil }
        var file = gitDir.appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("refs", isDirectory: true)
            .appendingPathComponent("heads", isDirectory: true)
        // A branch name carries its own path components: feature/login.
        for component in branch.split(separator: "/") {
            file.appendPathComponent(String(component))
        }
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }

        var entries: [ReflogEntry] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // The file is oldest first, and only the tail is interesting.
        for line in lines.suffix(limit).reversed() {
            guard let entry = ReflogEntry.parse(line: String(line),
                                                branch: branch,
                                                index: entries.count) else { continue }
            entries.append(entry)
        }
        return entries
    }

    /// Commits that are reachable from `dropped` but not from `kept`: what a
    /// move of the branch tip left behind.
    ///
    /// Returns nil when git could not answer — a pruned commit makes the range
    /// invalid — because an empty list has to mean "nothing left the branch".
    func commitsLeftBehind(kept: String, dropped: String, limit: Int) async -> [GitCommit]? {
        guard kept != dropped else { return [] }
        let format = "%H%x1f%s%x1f%an%x1f%ar"
        guard let result = try? await git(["log",
                                           "-n", "\(limit)",
                                           "--pretty=format:\(format)",
                                           kept + ".." + dropped]),
              result.ok else { return nil }
        var commits: [GitCommit] = []
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4 else { continue }
            commits.append(GitCommit(sha: fields[0], subject: fields[1], author: fields[2], relativeDate: fields[3]))
        }
        return commits
    }

    /// Which of the commits that left the branch have an equivalent patch on
    /// it now. `git cherry` marks those "-" and the genuinely gone ones "+".
    ///
    /// This is what tells a rebase apart from a loss. `pull --rebase` replays
    /// a local commit under a new sha: the old sha is gone, the work is not,
    /// and calling that "removed" is a lie.
    ///
    /// Returns nil when git could not answer. The caller then treats
    /// everything as gone, which is the cautious direction.
    func rewrittenShas(kept: String, dropped: String) async -> Set<String>? {
        guard kept != dropped else { return [] }
        guard let result = try? await git(["cherry", kept, dropped], timeout: 20),
              result.ok else { return nil }
        var rewritten = Set<String>()
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 2, fields[0] == "-" else { continue }
            rewritten.insert(fields[1])
        }
        return rewritten
    }

    /// The commit a ref points at, or nil when there is no such ref.
    func resolve(_ ref: String) async -> String? {
        guard let result = try? await git(["rev-parse", "--verify", "--quiet", ref + "^{commit}"]),
              result.ok else { return nil }
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Puts a branch at one commit without switching to it. Nothing else in the
    /// repository changes, which makes this the recovery that cannot go wrong.
    func createBranch(named name: String, at sha: String) async throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw GitError.emptyBranchName }
        return try await gitOK(["branch", clean, sha], timeout: 60)
    }

    /// Moves the current branch back to a commit. `--keep`, never `--hard`:
    /// git refuses when an uncommitted change would be overwritten instead of
    /// throwing it away, and the position it moves away from stays in the
    /// reflog, so the move is itself recoverable.
    func resetKeep(to sha: String) async throws -> String {
        return try await gitOK(["reset", "--keep", sha], timeout: 120)
    }

    // MARK: - Branches

    /// Local branches and the ones on origin, most recently committed first.
    /// Tabs separate the fields: a ref name can never contain one.
    func branches() async -> [GitBranch] {
        let format = "%(refname)%09%(refname:short)%09%(upstream:short)%09%(committerdate:relative)%09%(HEAD)"
        guard let output = try? await gitOK(["for-each-ref",
                                             "--sort=-committerdate",
                                             "--format=\(format)",
                                             "refs/heads", "refs/remotes"]) else { return [] }

        var locals: [GitBranch] = []
        var remotes: [GitBranch] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5, !fields[1].isEmpty else { continue }

            let fullRef = fields[0]
            let isRemoteRef = fullRef.hasPrefix("refs/remotes/")
            // Every remote has a symbolic HEAD, which is not a branch.
            if isRemoteRef && fullRef.hasSuffix("/HEAD") { continue }

            var remote: String?
            if isRemoteRef {
                let rest = fullRef.dropFirst("refs/remotes/".count)
                remote = rest.split(separator: "/").first.map(String.init)
            }

            let branch = GitBranch(name: fields[1],
                                   remote: remote,
                                   isCurrent: fields[4].trimmingCharacters(in: .whitespaces) == "*",
                                   upstream: fields[2].isEmpty ? nil : fields[2],
                                   relativeDate: fields[3])
            if branch.isRemote { remotes.append(branch) } else { locals.append(branch) }
        }

        // Hide a remote branch that already has a local copy, by name or by
        // being the upstream of a local branch with a different name.
        let localNames = Set(locals.map { $0.name })
        let tracked = Set(locals.compactMap { $0.upstream })
        return locals + remotes.filter {
            !localNames.contains($0.localName) && !tracked.contains($0.name)
        }
    }

    /// Switches branches without ever discarding work: `git switch` refuses when
    /// a file would be overwritten, and no force flag is used here.
    func switchBranch(to branch: GitBranch) async throws -> String {
        var arguments: [String]
        if branch.isRemote {
            arguments = ["switch", "--track", branch.name]
        } else {
            arguments = ["switch", branch.name]
        }
        let result = try await git(arguments, timeout: 120)
        if result.ok { return result.stdout + result.stderr }

        // Older git without `switch`.
        let unknown = result.stderr.lowercased().contains("is not a git command")
            || result.stderr.lowercased().contains("unknown option")
        guard unknown else {
            throw ShellError.failed(command: arguments.joined(separator: " "),
                                    status: result.status,
                                    stderr: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        let fallback = branch.isRemote
            ? ["checkout", "-b", branch.localName, "--track", branch.name]
            : ["checkout", branch.name]
        return try await gitOK(fallback)
    }

    /// Creates a branch from the current HEAD and switches to it. Fails, never
    /// overwrites, when the name is taken.
    func createBranch(named name: String) async throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw GitError.emptyBranchName }
        let result = try await git(["switch", "-c", clean], timeout: 120)
        if result.ok { return result.stdout + result.stderr }
        let unknown = result.stderr.lowercased().contains("is not a git command")
        guard unknown else {
            throw ShellError.failed(command: "switch -c \(clean)",
                                    status: result.status,
                                    stderr: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return try await gitOK(["checkout", "-b", clean])
    }

    /// Rebases the local commits on top of the upstream. Refuses on a dirty
    /// tree instead of stashing behind the user's back.
    func pull() async throws -> String {
        let result = try await runner.run(["pull", "--rebase"], timeout: 180)
        guard result.ok else {
            throw ShellError.failed(command: "pull --rebase",
                                    status: result.status,
                                    stderr: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result.stdout + result.stderr
    }

    /// The way out of a rebase that went wrong: back to where it started.
    /// Carries an interrupted rebase forward. The editor is disabled in the
    /// environment, so this can never block waiting for input.
    func continueRebase() async throws -> String {
        return try await gitOK(["rebase", "--continue"], timeout: 180)
    }

    /// Which of these files still contain conflict markers. Read straight from
    /// disk: the app never trusts "the agent said it fixed it".
    func filesWithConflictMarkers(_ paths: [String]) -> [String] {
        var remaining: [String] = []
        for path in paths {
            let url = root.appendingPathComponent(path)
            // Unreadable means unverified: a binary or non UTF-8 conflict is
            // never reported as resolved.
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                remaining.append(path)
                continue
            }
            // Only the opening and closing markers count. A bare "=======" is
            // also a markdown heading underline.
            var marked = false
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("<<<<<<< ") || line.hasPrefix("||||||| ") || line.hasPrefix(">>>>>>> ") {
                    marked = true
                    break
                }
            }
            if marked { remaining.append(path) }
        }
        return remaining
    }

    func abortRebase() async throws {
        try await gitOK(["rebase", "--abort"])
    }

    /// Appends one pattern to .gitignore, creating the file when there is none.
    /// Never rewrites or reorders what is already in there.
    func addToGitignore(_ pattern: String) throws {
        let url = root.appendingPathComponent(".gitignore")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let existing = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !existing.contains(pattern) else { return }
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += pattern + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Stash

    /// Every entry in the stash, newest first. \u{1f} separates the fields
    /// because a stash message can contain anything else.
    ///
    /// Returns nil when the read itself failed: an empty list has to mean
    /// "nothing is stashed", never "I could not tell".
    func stashes() async -> [GitStashEntry]? {
        let format = "%gd%x1f%gs%x1f%H%x1f%ct"
        guard let output = try? await gitOK(["stash", "list", "--format=\(format)"]) else { return nil }
        var entries: [GitStashEntry] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, !fields[0].isEmpty, !fields[2].isEmpty else { continue }
            entries.append(GitStashEntry(ref: fields[0],
                                         index: GitStashEntry.index(in: fields[0]) ?? entries.count,
                                         sha: fields[2],
                                         subject: fields[1],
                                         date: Date(timeIntervalSince1970: TimeInterval(fields[3]) ?? 0)))
        }
        return entries
    }

    /// The patch one stash would apply. Untracked files are included where git
    /// supports it, and left out on an older git instead of failing.
    func stashDiff(ref: String, contextLines: Int = 3) async -> String {
        let base = ["stash", "show", "--patch", "--no-color", "-U\(contextLines)"]
        if let result = try? await git(base + ["--include-untracked", ref]), result.ok {
            return result.stdout
        }
        let result = try? await git(base + [ref])
        return result?.stdout ?? ""
    }

    /// Applies a stash and leaves it in the list.
    func stashApply(ref: String) async throws -> String {
        return try await gitOK(["stash", "apply", ref], timeout: 120)
    }

    /// Applies a stash and removes it. When the apply ends in conflicts git
    /// keeps the entry, so nothing is lost either way.
    func stashPop(ref: String) async throws -> String {
        return try await gitOK(["stash", "pop", ref], timeout: 120)
    }

    /// Removes one entry. Only ever called after the user confirms it, and the
    /// commit stays reachable by its sha until git prunes it.
    func stashDrop(ref: String) async throws -> String {
        return try await gitOK(["stash", "drop", ref], timeout: 60)
    }

    /// Creates a branch at the commit the stash was made on, applies the stash
    /// there and drops it. Git refuses when the name is taken.
    func stashBranch(named name: String, ref: String) async throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw GitError.emptyBranchName }
        return try await gitOK(["stash", "branch", clean, ref], timeout: 120)
    }

    /// Moves the working tree into the stash, untracked files included. Nothing
    /// is lost: `stash pop` brings it all back.
    func stash(message: String) async throws -> String {
        return try await gitOK(["stash", "push", "--include-untracked", "-m", message], timeout: 120)
    }

    func stashPop() async throws -> String {
        return try await gitOK(["stash", "pop"], timeout: 120)
    }

    // MARK: - Staging (non destructive)

    func stage(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await gitOK(["add", "--"] + paths, timeout: 90)
    }

    func stageAll() async throws {
        try await gitOK(["add", "-A"], timeout: 120)
    }

    func unstage(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let result = try await git(["restore", "--staged", "--"] + paths, timeout: 90)
        if !result.ok {
            // A lock failure must surface, never fall through to a second
            // command that would only half apply the operation.
            guard !GitFailure.isLockContention(result.stderr) else {
                throw ShellError.failed(command: "restore --staged",
                                        status: result.status,
                                        stderr: result.stderr)
            }
            // Older git, or a repository without HEAD yet. `reset` here only
            // touches the index, never the working tree.
            try await gitOK(["reset", "-q", "--"] + paths, timeout: 90)
        }
    }

    /// Restores the given tracked paths to HEAD. Only ever called for paths the
    /// user confirmed in a dialog. Never touches anything else in the tree.
    func discard(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let restored = try await git(["restore", "--staged", "--worktree", "--"] + paths, timeout: 90)
        if !restored.ok {
            guard !GitFailure.isLockContention(restored.stderr) else {
                throw ShellError.failed(command: "restore --staged --worktree",
                                        status: restored.status,
                                        stderr: restored.stderr)
            }
            try await gitOK(["restore", "--worktree", "--"] + paths, timeout: 90)
        }
    }

    // MARK: - Commit and push

    func commit(message: String) async throws -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitError.emptyCommitMessage }
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("git-agent-commit-\(UUID().uuidString).txt")
        try trimmed.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        return try await gitOK(["commit", "--cleanup=strip", "-F", file.path], timeout: 240)
    }

    /// Has its own timeout, so a push waiting on credentials cannot hang
    /// forever. It waits its turn like every other git command.
    func push(setUpstream: Bool, branch: String) async throws -> String {
        var arguments = ["push"]
        if setUpstream {
            arguments.append(contentsOf: ["--set-upstream", "origin", branch])
        }
        let result = try await runner.runNetwork(arguments, timeout: 120)
        guard result.ok else {
            throw ShellError.failed(command: "push",
                                    status: result.status,
                                    stderr: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result.stdout + result.stderr
    }
}

/// Remembers pid -> ppid while one lock is being inspected.
final class ParentCache {
    var parents: [Int32: Int32] = [:]
}

enum GitError: LocalizedError {
    case notARepository(String)
    case emptyCommitMessage
    case emptyBranchName
    case commandRefused(String)

    var errorDescription: String? {
        switch self {
        case .notARepository(let path):
            return "\(path) is not a git repository."
        case .emptyCommitMessage:
            return "The commit message is empty."
        case .emptyBranchName:
            return "The branch name is empty."
        case .commandRefused(let command):
            return "\(command) is not a command Git Agent runs."
        }
    }
}
