import Foundation

// MARK: - Matching

enum SearchMatch {
    /// The query, split into the words a candidate has to contain.
    static func words(_ query: String) -> [String] {
        return query.lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Every word of the query has to appear somewhere in the candidate. No
    /// fuzzy matching on purpose: a result is always explainable by the text
    /// that is on screen.
    static func matches(words needle: [String], in lowered: String) -> Bool {
        guard !needle.isEmpty else { return true }
        for word in needle where !lowered.contains(word) { return false }
        return true
    }

    static func matches(_ query: String, in candidates: [String]) -> Bool {
        return matches(words: words(query), in: candidates.joined(separator: " ").lowercased())
    }
}

// MARK: - Query

/// What the palette should look through. "branch: main" narrows to branches,
/// "\u{203a} " means commands only.
enum SearchScope {
    case all
    case commands
    case commits
    case branches
    case files
    case author
}

struct SearchQuery {
    let scope: SearchScope
    /// What to match, with the prefix removed.
    let text: String

    /// Longest first, so "commits:" is never read as "commit:" plus "s:".
    private static let prefixes: [(String, SearchScope)] = [
        ("commits:", .commits),
        ("commit:", .commits),
        ("branches:", .branches),
        ("branch:", .branches),
        ("files:", .files),
        ("file:", .files),
        ("author:", .author),
        ("by:", .author)
    ]

    init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(">") {
            self.scope = .commands
            self.text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            return
        }
        let lower = trimmed.lowercased()
        var found: (SearchScope, String)?
        for (prefix, value) in SearchQuery.prefixes where lower.hasPrefix(prefix) {
            found = (value, String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
            break
        }
        self.scope = found?.0 ?? .all
        self.text = found?.1 ?? trimmed
    }

    /// A scope was named but nothing to look for was typed yet.
    var isBareScope: Bool { return scope != .all && text.isEmpty }

    /// Scanning the whole file list is not a per-keystroke job.
    var needsFileSearch: Bool {
        switch scope {
        case .commands, .branches, .commits, .author:
            return false
        case .files:
            return !text.isEmpty
        case .all:
            return text.count >= 2
        }
    }

    /// Whether git has to walk the commit graph to answer this.
    var needsCommitSearch: Bool {
        switch scope {
        case .commands, .branches, .files:
            return false
        case .commits, .author:
            return !text.isEmpty
        case .all:
            return text.count >= 2
        }
    }
}

// MARK: - Commands

/// A thing the palette can do. It carries no behaviour: the session decides
/// how each one runs, so this stays free of any view or repository.
enum PaletteCommand: Hashable {
    case checkout(String)
    case createBranch(String)
    case stash
    case popStash
    case fetch
    case pull
    case push
    case review
    case generateMessage
    case refresh
    case abortRebase
    case showChanges
    case showActivity
    case showStashes
    case showRecovery
    case showRebase
    case showForge
    case showWorkflows
    case createWorkflow
    case askAgent
    case syncPull
    case openOnWeb

    var label: String {
        switch self {
        case .checkout(let name): return "Checkout " + name
        case .createBranch(let name): return "Create branch " + name
        case .stash: return "Stash changes"
        case .popStash: return "Pop the latest stash"
        case .fetch: return "Fetch from origin"
        case .pull: return "Pull (rebase)"
        case .push: return "Push\u{2026}"
        case .review: return "Review changes with AI"
        case .generateMessage: return "Generate commit message"
        case .refresh: return "Refresh"
        case .abortRebase: return "Abort rebase"
        case .showChanges: return "Show all changes"
        case .showActivity: return "Show activity"
        case .showStashes: return "Show stashes"
        case .showRecovery: return "Show recovery"
        case .showRebase: return "Reorganize commits"
        case .showForge: return "Show pull requests"
        case .showWorkflows: return "Show workflows"
        case .createWorkflow: return "Create a workflow"
        case .askAgent: return "Ask the agent\u{2026}"
        case .syncPull: return "Sync & Pull"
        case .openOnWeb: return "Open the repository on the web"
        }
    }

    var hint: String? {
        switch self {
        case .checkout: return "switch to it"
        case .createBranch: return "from the current HEAD"
        case .stash: return "nothing is lost"
        case .popStash: return nil
        case .fetch: return "\u{21e7}\u{2318}F"
        case .pull: return "\u{21e7}\u{2318}P"
        case .push: return nil
        case .review: return "\u{21e7}\u{2318}R"
        case .generateMessage: return "\u{21e7}\u{2318}G"
        case .refresh: return "\u{2318}R"
        case .abortRebase: return "back to before the rebase"
        case .showChanges: return "\u{2318}1"
        case .showActivity: return "\u{2318}2"
        case .showStashes: return "\u{2318}3"
        case .showRecovery: return "\u{2318}4"
        case .showRebase: return "\u{2318}5"
        case .showForge: return "\u{2318}6"
        case .showWorkflows: return "\u{2318}7"
        case .createWorkflow: return "from scratch"
        case .askAgent: return "\u{2318}L"
        case .syncPull: return "\u{21e7}\u{2318}S"
        case .openOnWeb: return "in your browser"
        }
    }

    /// What the query is matched against.
    var keywords: [String] {
        switch self {
        case .checkout(let name): return ["checkout", "switch", name]
        case .createBranch(let name): return ["create", "new", "branch", name]
        case .stash: return ["stash", "push", "park", "changes"]
        case .popStash: return ["pop", "stash", "unstash", "restore"]
        case .fetch: return ["fetch", "origin", "remote"]
        case .pull: return ["pull", "rebase", "origin"]
        case .push: return ["push", "origin", "upload"]
        case .review: return ["review", "ai", "check", "changes"]
        case .generateMessage: return ["generate", "commit", "message", "ai"]
        case .refresh: return ["refresh", "reload", "status"]
        case .abortRebase: return ["abort", "rebase", "cancel"]
        case .showChanges: return ["show", "changes", "diff", "all"]
        case .showActivity: return ["show", "activity", "timeline", "log", "history"]
        case .showStashes: return ["show", "stashes", "stash", "manager"]
        case .showRecovery: return ["show", "recovery", "undo", "reflog", "restore", "lost"]
        case .showRebase: return ["rebase", "reorganize", "reorder", "squash", "reword", "drop", "interactive"]
        case .showForge: return ["pull", "request", "pr", "merge", "github", "gitlab", "issues", "ci", "checks", "reviews"]
        case .showWorkflows: return ["workflow", "workflows", "automate", "run", "sequence", "promote"]
        case .createWorkflow: return ["create", "new", "workflow", "automate"]
        case .askAgent: return ["ask", "chat", "agent", "ai", "help", "question", "talk"]
        case .syncPull: return ["sync", "pull", "update", "rebase", "remote", "behind", "atualizar"]
        case .openOnWeb: return ["open", "github", "gitlab", "web", "browser", "site", "repository", "abrir", "repo"]
        }
    }
}

// MARK: - Commit search

/// A commit and its message body. `git log --grep` looks at the whole message,
/// so the body has to come back too — otherwise a row appears with nothing on
/// it that explains the match.
struct CommitMatch {
    let commit: GitCommit
    let body: String

    /// The first line of the body that matches, when the subject does not.
    func matchedLine(for words: [String]) -> String? {
        guard !words.isEmpty else { return nil }
        if SearchMatch.matches(words: words, in: commit.subject.lowercased()) { return nil }
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let lowered = line.lowercased()
            guard SearchMatch.matches(words: words, in: lowered) else { continue }
            return line.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

// MARK: - Results

/// One row in the palette.
enum SearchHit: Identifiable, Hashable {
    case command(PaletteCommand)
    case branch(GitBranch)
    /// The line of the message body that matched, when the subject did not.
    /// Without it a body-only match looks like it has nothing to do with the
    /// query.
    case commit(GitCommit, matchedLine: String?)
    case file(String)
    case workflow(GitWorkflow)

    var id: String {
        switch self {
        case .command(let command): return "c:" + String(describing: command)
        case .branch(let branch): return "b:" + branch.id
        case .commit(let commit, _): return "h:" + commit.sha
        case .file(let path): return "f:" + path
        case .workflow(let value): return "w:" + value.id.uuidString
        }
    }

    var group: String {
        switch self {
        case .command: return "Commands"
        case .branch: return "Branches"
        case .commit: return "Commits"
        case .file: return "Files"
        case .workflow: return "Workflows"
        }
    }

    var title: String {
        switch self {
        case .command(let command): return command.label
        case .branch(let branch): return branch.isRemote ? branch.localName : branch.name
        case .commit(let commit, _): return commit.subject
        case .file(let path): return (path as NSString).lastPathComponent
        case .workflow(let value): return value.name
        }
    }

    var subtitle: String? {
        switch self {
        case .command(let command): return command.hint
        case .branch(let branch): return branch.remote
        case .commit(let commit, let matched): return matched ?? commit.author
        case .file(let path):
            let directory = (path as NSString).deletingLastPathComponent
            return directory.isEmpty ? nil : directory
        case .workflow(let value): return value.flowLabel()
        }
    }

    /// Two lists can offer the same row \u{2014} "checkout dev" narrows to
    /// branches, and the broad search offers branches too. A duplicate id in a
    /// ForEach is undefined behaviour, so the list is always deduplicated.
    static func deduplicated(_ hits: [SearchHit]) -> [SearchHit] {
        var seen = Set<String>()
        var result: [SearchHit] = []
        for hit in hits where seen.insert(hit.id).inserted {
            result.append(hit)
        }
        return result
    }

    /// The quiet text on the right of the row.
    var trailing: String? {
        switch self {
        case .command: return nil
        case .branch(let branch): return branch.relativeDate
        case .commit(let commit, _): return commit.shortSha + " \u{00b7} " + commit.relativeDate
        case .file: return nil
        case .workflow(let value): return value.stepCountLabel
        }
    }
}
