import Foundation

// MARK: - File status

enum FileStatus: String {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case typeChanged
    case untracked
    case conflict

    var badge: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .untracked: return "?"
        case .conflict: return "!"
        }
    }

    var label: String {
        switch self {
        case .modified: return "Modified"
        case .added: return "Added"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .copied: return "Copied"
        case .typeChanged: return "Type changed"
        case .untracked: return "Untracked"
        case .conflict: return "Conflict"
        }
    }

    static func from(code: Character) -> FileStatus {
        switch code {
        case "M": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        case "U": return .conflict
        case "?": return .untracked
        default: return .modified
        }
    }
}

// MARK: - Changed file

struct FileChange: Identifiable, Hashable {
    let path: String
    var originalPath: String?
    var status: FileStatus
    var staged: Bool
    var unstaged: Bool
    var additions: Int = 0
    var deletions: Int = 0

    var id: String { return path }
    var fileName: String { return (path as NSString).lastPathComponent }
    var directory: String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "" : parent
    }
    var isSensitive: Bool { return SensitiveFiles.isSensitive(path) }

    static func == (lhs: FileChange, rhs: FileChange) -> Bool {
        return lhs.path == rhs.path
            && lhs.status == rhs.status
            && lhs.staged == rhs.staged
            && lhs.unstaged == rhs.unstaged
            && lhs.additions == rhs.additions
            && lhs.deletions == rhs.deletions
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }
}

// MARK: - Commit

struct GitCommit: Identifiable, Hashable {
    let sha: String
    let subject: String
    let author: String
    let relativeDate: String

    var id: String { return sha }
    var shortSha: String { return String(sha.prefix(7)) }
}

// MARK: - Branch

struct GitBranch: Identifiable, Hashable {
    /// Short name: "main", or "origin/feature" for a remote branch.
    let name: String
    /// The remote this ref lives on, nil for a local branch. Taken from the
    /// ref namespace, never guessed from the name.
    let remote: String?
    let isCurrent: Bool
    let upstream: String?
    let relativeDate: String

    var isRemote: Bool { return remote != nil }
    var id: String { return (isRemote ? "r:" : "l:") + name }

    /// The local name a remote branch would get when checked out.
    var localName: String {
        guard let remote, name.hasPrefix(remote + "/") else { return name }
        return String(name.dropFirst(remote.count + 1))
    }
}

// MARK: - Stash

/// One entry in `git stash list`. The ref shifts whenever an entry is added or
/// dropped, so identity is the commit sha and only git commands use the ref.
struct GitStashEntry: Identifiable, Hashable {
    /// "stash@{0}", straight from git.
    let ref: String
    let index: Int
    let sha: String
    /// The reflog subject git wrote for it, unparsed.
    let subject: String
    let date: Date

    var id: String { return sha }
    var shortSha: String { return String(sha.prefix(7)) }

    /// git writes the subject itself: "WIP on main: a83f21 feat: login" for an
    /// automatic stash, "On main: message" for one that was given a message.
    private var parsed: (branch: String?, message: String) {
        if subject.hasPrefix("WIP on ") {
            let rest = subject.dropFirst("WIP on ".count)
            guard let colon = rest.firstIndex(of: ":") else { return (nil, subject) }
            let branch = String(rest[..<colon])
            var message = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // The automatic form starts with the commit the stash was made on.
            if let space = message.firstIndex(of: " ") {
                let head = message[..<space]
                if head.count >= 4, head.allSatisfy({ $0.isHexDigit }) {
                    message = String(message[message.index(after: space)...])
                }
            }
            return (branch.isEmpty ? nil : branch, message.isEmpty ? subject : message)
        }
        if subject.hasPrefix("On ") {
            let rest = subject.dropFirst("On ".count)
            guard let colon = rest.firstIndex(of: ":") else { return (nil, subject) }
            let branch = String(rest[..<colon])
            let message = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            return (branch.isEmpty ? nil : branch, message.isEmpty ? subject : message)
        }
        return (nil, subject)
    }

    /// The branch the stash was made on, when git recorded one.
    var branch: String? { return parsed.branch }
    /// What the user actually wrote, or the commit subject for an automatic stash.
    var title: String { return parsed.message }

    /// "Today 06:31", "Yesterday 18:42", "12 Mar 18:42".
    var when: String {
        let calendar = Calendar.current
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        if calendar.isDateInToday(date) { return "Today " + time.string(from: date) }
        if calendar.isDateInYesterday(date) { return "Yesterday " + time.string(from: date) }
        let full = DateFormatter()
        full.dateFormat = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
            ? "d MMM HH:mm"
            : "d MMM yyyy"
        return full.string(from: date)
    }

    /// A name to offer when branching off this stash. ASCII only, so git can
    /// never reject the suggestion itself.
    var suggestedBranchName: String {
        var slug = ""
        var lastWasDash = false
        for character in title.lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber) {
                slug.append(character)
                lastWasDash = false
            } else if !slug.isEmpty && !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.count > 40 {
            slug = String(slug.prefix(40))
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        return slug.isEmpty ? "stash-\(index)" : "stash/\(slug)"
    }

    /// Reads the number out of "stash@{12}".
    static func index(in ref: String) -> Int? {
        guard let open = ref.firstIndex(of: "{"),
              let close = ref.lastIndex(of: "}"),
              open < close else { return nil }
        return Int(ref[ref.index(after: open)..<close])
    }
}

// MARK: - Reflog and recovery

/// One move of a ref, as git itself recorded it in the reflog. Read only: the
/// app never writes the reflog, it reads what git already kept.
struct ReflogEntry: Identifiable, Hashable {
    /// 0 is the most recent move.
    let index: Int
    /// "main@{0}". Display only — every command uses the raw sha.
    let selector: String
    /// Where the ref pointed **before** this move.
    let old: String
    /// Where it pointed after.
    let sha: String
    /// "reset", "rebase (finish)", "commit", "commit (amend)".
    let action: String
    /// The rest of git's own description of the move.
    let message: String
    let date: Date

    var id: String { return "\(Int(date.timeIntervalSince1970))-\(old.prefix(12))-\(sha.prefix(12))" }
    var shortSha: String { return String(sha.prefix(7)) }
    var shortOld: String { return String(old.prefix(7)) }

    /// The line that created the ref has no previous value: git writes all
    /// zeros there.
    var isCreation: Bool { return old.allSatisfy { $0 == "0" } }

    /// A move that can only add commits is not worth a `git log` to confirm.
    var couldLoseCommits: Bool {
        switch action {
        case "commit", "commit (initial)", "branch", "clone":
            return false
        default:
            return true
        }
    }

    /// "now", "12m ago", "3h ago", "2d ago".
    var relative: String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    /// git writes the subject as "<action>: <what it did>".
    static func split(subject: String) -> (action: String, message: String) {
        guard let separator = subject.range(of: ": ") else {
            return (subject.trimmingCharacters(in: .whitespaces), "")
        }
        return (String(subject[..<separator.lowerBound]),
                String(subject[separator.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    /// One line of a reflog file:
    ///
    ///     <old sha> <new sha> <name> <email> <unix time> <tz>\t<action>: <message>
    ///
    /// The identity in the middle can contain spaces, so the timestamp is
    /// found from the end rather than by position.
    static func parse(line: String, branch: String, index: Int) -> ReflogEntry? {
        let halves = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let head = halves.first else { return nil }
        let fields = head.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 4 else { return nil }
        let old = fields[0]
        let sha = fields[1]
        guard old.count >= 7, sha.count >= 7 else { return nil }

        // Unparseable time must not read as "just now": a gate that means
        // "recent" has to fail closed.
        var date = Date.distantPast
        for candidate in fields.suffix(2) {
            // The zone reads as a small number ("-0400"), the timestamp does not.
            if let seconds = TimeInterval(candidate), seconds > 1_000_000 {
                date = Date(timeIntervalSince1970: seconds)
            }
        }

        let parts = split(subject: halves.count > 1 ? halves[1] : "")
        return ReflogEntry(index: index,
                           selector: "\(branch)@{\(index)}",
                           old: old,
                           sha: sha,
                           action: parts.action,
                           message: parts.message,
                           date: date)
    }
}

/// One place the current branch has been, and what going back there would
/// recover. `from` is the value git recorded for the ref before the move, so
/// it is exact even when `git gc` has expired entries in the middle.
struct RecoveryPoint: Identifiable, Hashable {
    let branch: String
    let entry: ReflogEntry
    /// Where the branch pointed before the move. This is what "go back" means.
    let from: String
    /// Where it pointed after.
    let to: String
    /// Commits that left the branch and have no equivalent on it now: the ones
    /// that are actually gone. Empty for a move that only added commits, and
    /// empty for a rebase that replayed everything under new shas.
    let lost: [GitCommit]
    /// Commits that left the branch but whose patch is back under a new sha.
    /// A `pull --rebase` is all of these and none of the above.
    let rewritten: Int
    /// git has more of them than were read.
    let moreLost: Bool
    /// The commits behind this move have been counted. False while a count is
    /// still pending, and when the count itself could not be made.
    let counted: Bool

    /// Stable across ref updates: the reflog renumbers every entry on every
    /// move, so the selector cannot be part of identity.
    var id: String { return entry.id }
    var shortFrom: String { return String(from.prefix(7)) }
    var isLoss: Bool { return !lost.isEmpty }

    var lostLabel: String {
        if lost.count == 1 && !moreLost { return "1 commit" }
        return "\(lost.count)\(moreLost ? "+" : "") commits"
    }

    /// True when the move only replayed commits: nothing is missing.
    var isRewriteOnly: Bool { return lost.isEmpty && rewritten > 0 }

    var rewrittenLabel: String {
        return rewritten == 1 ? "1 commit rewritten" : "\(rewritten) commits rewritten"
    }
}

// MARK: - Repository state

struct RepoState {
    var root: URL
    var branch: String = ""
    var upstream: String?
    var ahead: Int = 0
    var behind: Int = 0
    var detached: Bool = false
    var isMerging: Bool = false
    var isRebasing: Bool = false
    var changes: [FileChange] = []
    var recentCommits: [GitCommit] = []

    var conflicts: [FileChange] { return changes.filter { $0.status == .conflict } }
    var hasConflicts: Bool { return !conflicts.isEmpty }
    var hasChanges: Bool { return !changes.isEmpty }
    var stagedChanges: [FileChange] { return changes.filter { $0.staged && $0.status != .conflict } }
    var unstagedChanges: [FileChange] { return changes.filter { $0.unstaged || $0.status == .untracked } }
    var totalAdditions: Int { return changes.reduce(0) { $0 + $1.additions } }
    var totalDeletions: Int { return changes.reduce(0) { $0 + $1.deletions } }

    var branchLabel: String {
        if detached { return "detached HEAD" }
        return branch.isEmpty ? "unknown" : branch
    }

    var syncLabel: String? {
        if upstream == nil { return "no upstream" }
        if ahead > 0 && behind > 0 { return "\u{2191}\(ahead) \u{2193}\(behind)" }
        if ahead > 0 { return "\u{2191}\(ahead)" }
        if behind > 0 { return "\u{2193}\(behind)" }
        return nil
    }
}

// MARK: - Sensitive files

enum SensitiveFiles {
    private static let needles = [
        "id_rsa", "id_ed25519", "id_dsa", ".pem", ".p12", ".pfx", ".keystore",
        "credentials", "secrets", "secret.", ".key", "serviceaccount", ".netrc", ".npmrc"
    ]

    static func isSensitive(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        if name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env") { return true }
        for needle in needles where lower.contains(needle) { return true }
        return false
    }
}
