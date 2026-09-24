import Foundation

// MARK: - The failure being handed over

/// A git failure the user can hand to the agent, captured where it happened.
struct AIFailure: Identifiable, Hashable {
    let id = UUID()
    /// The git subcommand that failed, when it is known.
    let command: String?
    /// The app's own translation of it.
    let message: String
    /// git's own output, which is what the agent actually needs.
    let raw: String
    let date = Date()

    var commandLabel: String { return command.map { "git " + $0 } ?? "a git command" }
}

// MARK: - Policy

/// How much a git command can cost if it is wrong.
///
/// This is the app's verdict, worked out from the command itself. The agent's
/// opinion of its own commands is never used: a plan is a suggestion, and this
/// is the gate.
enum GitCommandRisk: Hashable {
    /// Changes nothing at all.
    case read
    /// Changes the repository, but nothing the user has can be lost: what it
    /// does stays reachable from the index, a stash or the reflog.
    case safe
    /// Can destroy uncommitted work, or make a commit unreachable. Never runs
    /// without the user confirming this exact command.
    case destructive
    /// Not allowed at all, whatever reason is given for it.
    case refused(String)

    var isRunnable: Bool {
        switch self {
        case .read, .safe, .destructive: return true
        case .refused: return false
        }
    }

    var needsConfirmation: Bool {
        if case .destructive = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .read: return "reads"
        case .safe: return "safe"
        case .destructive: return "needs you"
        case .refused: return "refused"
        }
    }
}

/// What may run, and in what shape.
///
/// Built as an allowlist of **subcommands and their options together**. The
/// obvious design — allow a subcommand, then look for dangerous flags — does
/// not hold: `git branch -f`, `git grep -O<program>`, `git log --output=<path>`
/// and `git push origin +main:main` all destroy something while looking
/// innocent, and every new git release adds more. Here an option that is not
/// named is refused, so the failure mode is a plan that will not run rather
/// than a repository that is gone.
///
/// One thing this cannot defend against, and does not pretend to: a repository
/// whose own config or .gitattributes runs a program on `git log -p`. That is
/// true of git itself and of every client, this app included, long before any
/// of this. What it does defend against is the **plan** choosing such a flag.
enum GitCommandPolicy {

    // MARK: Reading the command

    private struct Parsed {
        /// Every option, without its value: "--max-count=5" is "--max-count".
        let options: [String]
        /// Options written as --flag=value. The value is not kept anywhere, so
        /// a check on the flag alone cannot see it: --rebase=interactive would
        /// pass a check for --rebase and then open an editor nobody can reach.
        let inlineValues: [String]
        /// Positional arguments, and everything after a "--".
        let positionals: [String]
        var flags: Set<String> { return Set(options) }
    }

    /// Never acceptable, whatever the subcommand.
    ///
    /// --output writes any file on disk with content the command controls;
    /// -O and --open-files-in-pager run a program; --ext-diff, --textconv and
    /// --filters run whatever the repository configured; -c and the path
    /// options point git elsewhere; the force family overwrites work that is
    /// not committed anywhere; -p and -i want a terminal or a filter.
    private static let neverAllowed: Set<String> = [
        "--output", "--ext-diff", "--textconv", "--filters",
        "-O", "--open-files-in-pager", "--pager",
        "-C", "--config-env", "--exec-path", "--git-dir", "--work-tree",
        "--namespace", "--exec", "--upload-pack", "--receive-pack",
        "-f", "--force", "--force-with-lease", "--force-if-includes",
        "--force-create", "--hard", "--discard-changes", "--ignore-unmerged",
        "-p", "--patch", "-i", "--interactive", "--amend"
    ]

    private enum ParseResult {
        case ok(Parsed)
        case refused(String)
    }

    /// Splits "--flag=value" and rejects a short cluster like "-Df", so a check
    /// on one option can never be dodged by writing it another way.
    private static func parse(_ arguments: [String]) -> ParseResult {
        var options: [String] = []
        var positionals: [String] = []
        var inlineValues: [String] = []
        var afterSeparator = false

        for argument in arguments.dropFirst() {
            if afterSeparator {
                positionals.append(argument)
                continue
            }
            if argument == "--" {
                afterSeparator = true
                continue
            }
            if argument.hasPrefix("--") {
                if let equals = argument.firstIndex(of: "=") {
                    options.append(String(argument[..<equals]))
                    inlineValues.append(String(argument[..<equals]))
                } else {
                    options.append(argument)
                }
                continue
            }
            if argument.hasPrefix("-"), argument.count > 1 {
                if argument.count == 2 {
                    options.append(argument)
                    continue
                }
                // Anything longer is either a cluster (-Df) or a value glued on
                // (-n5), and telling them apart needs git's own table of which
                // short options take a value. Reading "-uf" as "-u with the
                // value f" is exactly how --force got through: git reads it as
                // -u -f, because -u takes no value. So neither form is
                // accepted, and the value goes in its own argument.
                return .refused("\(argument) puts several short options, or a value, into one argument \u{2014} write each one separately, as in -n 5")
            }
            positionals.append(argument)
        }
        return .ok(Parsed(options: options, inlineValues: inlineValues, positionals: positionals))
    }

    /// A remote or branch name, and nothing that could be a refspec. This is
    /// what stops "push origin +main:main" from being a force push.
    private static func isPlainName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200 else { return false }
        guard !value.hasPrefix("-"), !value.hasPrefix("/"), !value.hasPrefix(".") else { return false }
        guard !value.contains("..") else { return false }
        for character in value {
            guard character.isASCII else { return false }
            let allowed = character.isLetter || character.isNumber
                || character == "." || character == "_" || character == "-" || character == "/"
            guard allowed else { return false }
        }
        return true
    }

    /// A revision: a name, plus the few characters git uses to walk from one.
    private static func isRevision(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200 else { return false }
        guard !value.hasPrefix("-"), !value.hasPrefix("/") else { return false }
        guard !value.contains(":"), !value.contains("+"), !value.contains("*") else { return false }
        for character in value {
            guard character.isASCII, !character.isWhitespace else { return false }
            let allowed = character.isLetter || character.isNumber
                || "._-/^~@{}".contains(character)
            guard allowed else { return false }
        }
        return true
    }

    // MARK: The verdict

    /// The one place that decides what may run.
    static func classify(_ arguments: [String]) -> GitCommandRisk {
        guard let name = arguments.first, !name.isEmpty else {
            return .refused("there is no command here")
        }
        guard arguments.count <= 20 else {
            return .refused("too many arguments to be a command this app runs")
        }
        for argument in arguments {
            guard argument.count <= 512 else { return .refused("one argument is far too long") }
            guard !argument.contains("\n"), !argument.contains("\r"), !argument.contains("\0") else {
                return .refused("an argument contains a line break")
            }
        }
        // A leading option points git somewhere else. The app supplies its own
        // globals; a plan supplies a subcommand and nothing in front of it.
        guard !name.hasPrefix("-") else {
            return .refused("starts with \(name) instead of a git subcommand")
        }

        let parsed: Parsed
        switch parse(arguments) {
        case .refused(let why): return .refused(why)
        case .ok(let value): parsed = value
        }

        // A second layer. The per-subcommand lists are the gate; this catches
        // the one that gets forgotten, which is how --output slipped back in
        // through the one branch that skipped the check.
        if let banned = parsed.options.first(where: { neverAllowed.contains($0) }) {
            return .refused("\(banned) is never allowed, whatever the command \u{2014} it can write a file anywhere, run another program, or overwrite work")
        }
        let flags = parsed.flags
        let positionals = parsed.positionals

        /// The first option that is not on this subcommand's list.
        func stray(_ allowed: Set<String>) -> String? {
            return parsed.options.first { !allowed.contains($0) }
        }

        // Compared exactly: git is case sensitive too, so "RESET" is not a
        // command and refusing it here is the same answer git would give.
        switch name {

        // MARK: reads

        case "status":
            if let bad = stray(["--short", "-s", "--porcelain", "--branch", "-b",
                                "--untracked-files", "-u", "--no-color", "--long"]) {
                return .refused("git status \(bad) is not allowed here")
            }
            return .read

        case "log", "show", "diff":
            // No --output (it writes any file on disk with content the commits
            // control), no --ext-diff or --textconv (they run a program), no
            // -p/--patch (the app shows diffs itself, and a patch goes through
            // the repository's own filters).
            if let bad = stray(["-n", "--max-count", "--oneline", "--pretty", "--format",
                                "--no-color", "--graph", "--decorate", "--all", "--reverse",
                                "--stat", "--name-only", "--name-status", "--numstat",
                                "--first-parent", "--merges", "--no-merges", "--date",
                                "--abbrev-commit", "--author", "--grep", "--fixed-strings",
                                "--regexp-ignore-case", "--cached", "--staged",
                                "--shortstat", "--summary"]) {
                return .refused("git \(name) \(bad) is not allowed here")
            }
            return .read

        case "rev-parse", "rev-list", "merge-base", "cherry", "describe", "name-rev",
             "shortlog", "count-objects", "check-ignore", "ls-files", "for-each-ref":
            if let bad = stray(["-n", "--max-count", "--all", "--abbrev-ref", "--verify",
                                "--quiet", "-q", "--short", "--count", "--format",
                                "--sort", "--others", "--cached", "--modified", "--deleted",
                                "--stage", "-z", "--exclude-standard", "--is-inside-work-tree",
                                "--absolute-git-dir", "--show-toplevel", "--left-right",
                                "--tags", "--no-color", "-s", "-n1"]) {
                return .refused("git \(name) \(bad) is not allowed here")
            }
            return .read

        case "reflog":
            if positionals.contains("expire") || positionals.contains("delete") {
                return .refused("expiring the reflog removes the only way back")
            }
            if let bad = stray(["-n", "--max-count", "--date", "--format", "--pretty", "--no-color"]) {
                return .refused("git reflog \(bad) is not allowed here")
            }
            return .read

        // MARK: writes that lose nothing

        case "add":
            // No -p/-i: they want a terminal and would hang.
            if let bad = stray(["-A", "--all", "-u", "--update", "-N", "--intent-to-add",
                                "--renormalize"]) {
                return .refused("git add \(bad) is not allowed here")
            }
            return .safe

        case "commit":
            // No --amend and no -a: rewriting the last commit, or committing
            // everything, is not something to do without being asked.
            if let bad = stray(["-m", "--message", "--cleanup", "--allow-empty", "--no-verify",
                                "--quiet", "-q"]) {
                return .refused("git commit \(bad) is not allowed here \u{2014} amending and -a are not")
            }
            guard flags.contains("-m") || flags.contains("--message") else {
                return .refused("git commit needs its message given with -m")
            }
            return .safe

        case "stash":
            guard let action = positionals.first else {
                return .refused("git stash on its own is a push \u{2014} write the subcommand out")
            }
            switch action {
            case "list", "show":
                // Vetted like every other branch. These take git's diff
                // options, and --output among them writes any file on disk
                // with content --format controls.
                if let bad = stray(["-n", "--max-count", "--stat", "--numstat",
                                    "--name-only", "--name-status", "--include-untracked",
                                    "-u", "--quiet", "-q", "--no-color", "--date"]) {
                    return .refused("git stash \(action) \(bad) is not allowed here")
                }
                return .read
            case "push", "save", "apply", "pop", "branch":
                if let bad = stray(["-m", "--message", "--include-untracked", "-u",
                                    "--keep-index", "--staged", "--quiet", "-q", "--index"]) {
                    return .refused("git stash \(action) \(bad) is not allowed here")
                }
                return .safe
            case "drop", "clear":
                if let bad = stray(["--quiet", "-q"]) {
                    return .refused("git stash \(action) \(bad) is not allowed here")
                }
                return .destructive
            default:
                return .refused("git stash \(action) is not something this app runs")
            }

        case "switch":
            // No force, no --force-create, no --discard-changes: each of them
            // overwrites work that is not committed anywhere.
            if let bad = stray(["-c", "--create", "--track", "-t", "--quiet", "-q"]) {
                return .refused("git switch \(bad) is not allowed here")
            }
            for value in positionals where !isPlainName(value) {
                return .refused("\(value) is not a plain branch name")
            }
            guard positionals.count <= 2 else { return .refused("too many arguments for a branch switch") }
            return .safe

        case "branch":
            // Creating and renaming only. Moving a branch is what
            // Recovery is for, and deleting one is not a fix for a failure.
            if let bad = stray(["-m", "--move", "--list", "-a", "--all", "-v", "--verbose",
                                "--show-current", "--quiet", "-q"]) {
                return .refused("git branch \(bad) is not allowed here \u{2014} -f, -d, -D and -c are not")
            }
            for value in positionals where !isPlainName(value) {
                return .refused("\(value) is not a plain branch name")
            }
            guard positionals.count <= 2 else { return .refused("too many arguments for a branch") }
            return .safe

        case "rebase":
            if flags.contains("--abort") || flags.contains("--continue") || flags.contains("--skip") {
                if let bad = stray(["--abort", "--continue", "--skip", "--quiet", "-q"]) {
                    return .refused("git rebase \(bad) is not allowed alongside that")
                }
                // --continue carries on. --abort and --skip throw away a
                // conflict resolution that was never staged, and git keeps no
                // copy of that anywhere.
                if flags.contains("--continue") { return .safe }
                return .destructive
            }
            // Starting one. It rewrites commits, so it asks first; nothing is
            // lost either way, because what it rewrote stays in the reflog and
            // the Recovery panel reads the reflog.
            if let value = parsed.inlineValues.first {
                return .refused("\(value)=\u{2026} is not accepted here \u{2014} write the value as its own argument")
            }
            if let bad = stray(["--onto", "--autostash", "--quiet", "-q", "--no-autosquash",
                                "--keep-empty", "--no-keep-empty"]) {
                return .refused("git rebase \(bad) is not allowed here")
            }
            for value in positionals where !isRevision(value) {
                return .refused("\(value) is not a revision")
            }
            guard !positionals.isEmpty, positionals.count <= 3 else {
                return .refused("git rebase needs the branch to replay onto")
            }
            return .destructive

        case "merge":
            if flags.contains("--abort") || flags.contains("--continue") || flags.contains("--quit") {
                if let bad = stray(["--abort", "--continue", "--quit", "--quiet", "-q"]) {
                    return .refused("git merge \(bad) is not allowed alongside that")
                }
                // --quit leaves the working tree alone; --abort resets it, and
                // takes an unstaged resolution with it.
                if flags.contains("--abort") { return .destructive }
                return .safe
            }
            // A merge can stop on a conflict, and the app has a panel for
            // exactly that. It cannot lose a commit: the merge is one commit
            // on top, and --abort undoes it.
            if let value = parsed.inlineValues.first {
                return .refused("\(value)=\u{2026} is not accepted here \u{2014} write the value as its own argument")
            }
            if let bad = stray(["--no-ff", "--ff-only", "--no-edit",
                                "-m", "--message", "--quiet", "-q"]) {
                return .refused("git merge \(bad) is not allowed here")
            }
            for value in positionals where !isRevision(value) {
                return .refused("\(value) is not a revision")
            }
            guard !positionals.isEmpty, positionals.count <= 3 else {
                return .refused("git merge needs the branch to merge")
            }
            return .destructive

        case "pull":
            // Fetch plus rebase or merge, and both of those are allowed above.
            // It refuses by itself when the tree is dirty, it cannot lose a
            // commit, and when it stops on a conflict the app already knows
            // what to do with that.
            if let value = parsed.inlineValues.first {
                return .refused("\(value)=\u{2026} is not accepted here \u{2014} --rebase=interactive would open an editor this app cannot reach")
            }
            if let bad = stray(["--rebase", "--no-rebase", "--ff-only", "--no-ff",
                                "--autostash", "--quiet", "-q", "--tags", "--no-tags",
                                "--prune"]) {
                return .refused("git pull \(bad) is not allowed here")
            }
            for value in positionals where !isPlainName(value) {
                return .refused("\(value) is a refspec, and a refspec can force update a branch")
            }
            // An unknown remote name is a path to git, and a sibling clone or a
            // vendored fork on disk is a repository it will happily merge from.
            if let remote = positionals.first, remote.contains("/") {
                return .refused("\(remote) is a path, not a remote name \u{2014} git would pull from whatever repository is there")
            }
            guard positionals.count <= 2 else { return .refused("too many arguments for a pull") }
            return .destructive

        case "cherry-pick", "revert":
            if flags.contains("--abort") || flags.contains("--continue") || flags.contains("--quit") {
                if let bad = stray(["--abort", "--continue", "--quit"]) {
                    return .refused("git \(name) \(bad) is not allowed alongside that")
                }
                if flags.contains("--abort") { return .destructive }
                return .safe
            }
            if let bad = stray(["--no-edit", "-n", "--no-commit", "-x", "--mainline"]) {
                return .refused("git \(name) \(bad) is not allowed here")
            }
            for value in positionals where !isRevision(value) {
                return .refused("\(value) is not a revision")
            }
            guard !positionals.isEmpty, positionals.count <= 4 else {
                return .refused("git \(name) needs the commits to apply")
            }
            return .safe

        case "fetch":
            // A refspec here can force-update a local branch, so only a plain
            // remote name is accepted.
            if let bad = stray(["--prune", "--tags", "--quiet", "-q", "--all", "--no-tags"]) {
                return .refused("git fetch \(bad) is not allowed here")
            }
            for value in positionals where !isPlainName(value) {
                return .refused("\(value) is not a plain remote name \u{2014} a refspec can force update a branch")
            }
            if let remote = positionals.first, remote.contains("/") {
                return .refused("\(remote) is a path, not a remote name \u{2014} git would fetch from whatever repository is there")
            }
            guard positionals.count <= 1 else { return .refused("git fetch takes one remote here") }
            return .safe

        // MARK: writes that need the user

        case "reset":
            if flags.contains("--hard") {
                return .refused("reset --hard throws uncommitted work away \u{2014} --keep refuses instead, and the app uses that")
            }
            if let bad = stray(["--keep", "--soft", "--mixed", "--quiet", "-q"]) {
                return .refused("git reset \(bad) is not allowed here")
            }
            for value in positionals where !isRevision(value) {
                return .refused("\(value) is not a revision")
            }
            guard positionals.count <= 1 else {
                return .refused("git reset with paths discards work \u{2014} not from here")
            }
            return .destructive

        case "push":
            // No option that can force, and no refspec: both positionals have
            // to be plain names, which makes "+main:main" and ":branch"
            // impossible to express.
            if let bad = stray(["--set-upstream", "-u", "--quiet", "-q", "--tags"]) {
                return .refused("git push \(bad) is not allowed \u{2014} this app never force pushes")
            }
            for value in positionals where !isPlainName(value) {
                return .refused("\(value) is a refspec, and a refspec can force push or delete a branch")
            }
            guard positionals.count <= 2 else { return .refused("too many arguments for a push") }
            return .destructive

        default:
            return .refused("git \(name) is not on the list of commands this app runs")
        }
    }
}

// MARK: - One step

enum StepOutcome: Hashable {
    case pending
    case running
    case done(String)
    case failed(String)
    case skipped(String)

    var isTerminal: Bool {
        switch self {
        case .pending, .running: return false
        case .done, .failed, .skipped: return true
        }
    }
}

struct GitCommandStep: Identifiable, Hashable {
    let id = UUID()
    /// argv after "git", exactly as it will be run. No shell is involved, so
    /// nothing in here is ever interpreted.
    let arguments: [String]
    /// The agent's reason for it, in its own words.
    let why: String
    /// The app's verdict, never the agent's.
    let risk: GitCommandRisk
    var outcome: StepOutcome = .pending

    var display: String { return "git " + arguments.joined(separator: " ") }

    static func firstLines(_ text: String, _ count: Int = 3) -> String {
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(count)
            .joined(separator: "\n")
    }
}

// MARK: - The plan

struct GitCommandPlan {
    let diagnosis: String
    let note: String?
    var steps: [GitCommandStep]
    let rawText: String
    let parsed: Bool

    var refusedCount: Int {
        return steps.filter { if case .refused = $0.risk { return true } else { return false } }.count
    }
    var needsConfirmation: Bool { return steps.contains { $0.risk.needsConfirmation } }
    var isFinished: Bool { return steps.allSatisfy { $0.outcome.isTerminal } }
    var failedCount: Int {
        return steps.filter { if case .failed = $0.outcome { return true } else { return false } }.count
    }

    static func unparsed(_ text: String) -> GitCommandPlan {
        return GitCommandPlan(diagnosis: "",
                              note: nil,
                              steps: [],
                              rawText: text,
                              parsed: false)
    }
}

enum GitPlanParser {

    static func parse(_ text: String) -> GitCommandPlan {
        guard let object = JSONExtractor.firstObject(in: text) else { return .unparsed(text) }

        let diagnosis = JSONExtractor.string(object["diagnosis"]) ?? ""
        let note = JSONExtractor.string(object["note"])
        var steps: [GitCommandStep] = []

        if let array = object["steps"] as? [[String: Any]] {
            for entry in array {
                let why = JSONExtractor.string(entry["why"]) ?? ""
                guard let arguments = commandArguments(entry["command"]) else {
                    let raw = JSONExtractor.string(entry["command"]) ?? "(unreadable)"
                    steps.append(GitCommandStep(arguments: [raw],
                                                why: why,
                                                risk: .refused("this app only runs a command given as a list of arguments")))
                    continue
                }
                steps.append(GitCommandStep(arguments: arguments,
                                            why: why,
                                            risk: GitCommandPolicy.classify(arguments)))
            }
        }

        return GitCommandPlan(diagnosis: diagnosis,
                              note: note?.isEmpty == true ? nil : note,
                              steps: steps,
                              rawText: text,
                              parsed: !diagnosis.isEmpty || !steps.isEmpty)
    }

    /// A list of arguments, which is the only form that can be run without a
    /// shell. A plain string is accepted only when splitting it on spaces
    /// cannot change what it means.
    private static func commandArguments(_ value: Any?) -> [String]? {
        if let array = value as? [Any] {
            let strings = array.compactMap { JSONExtractor.string($0) }
            guard strings.count == array.count else { return nil }
            return trimmed(strings)
        }
        if let text = value as? String {
            guard !text.contains("\""), !text.contains("'"), !text.contains("|"),
                  !text.contains("&"), !text.contains(";"), !text.contains("$"),
                  !text.contains("`"), !text.contains(">"), !text.contains("<") else { return nil }
            let parts = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard !parts.isEmpty else { return nil }
            return trimmed(parts)
        }
        return nil
    }

    /// A plan usually writes "git status"; the leading word is ours to add.
    private static func trimmed(_ parts: [String]) -> [String]? {
        var values = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if values.first?.lowercased() == "git" { values.removeFirst() }
        return values.isEmpty ? nil : values
    }
}
