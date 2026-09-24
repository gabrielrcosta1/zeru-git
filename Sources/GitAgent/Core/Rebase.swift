import Foundation

// MARK: - Commits in the plan

/// A commit plus its parents, so a merge can be told apart from a plain one.
struct CommitNode: Hashable {
    let commit: GitCommit
    let parents: [String]

    var isMerge: Bool { return parents.count > 1 }
}

// MARK: - Actions

/// What to do with one commit when the sequence is replayed.
enum RebaseAction: String, CaseIterable, Hashable {
    case pick
    case squash
    case reword
    case drop

    var label: String { return rawValue.uppercased() }

    var help: String {
        switch self {
        case .pick: return "Keep it as it is"
        case .squash: return "Fold it into the commit above, keeping that commit's message"
        case .reword: return "Keep the changes, write a new message"
        case .drop: return "Leave it out. The commit stays recoverable from Recovery."
        }
    }
}

/// One row of the plan. The commit never changes; everything else is the
/// user's decision.
struct RebaseStep: Identifiable, Hashable {
    let commit: GitCommit
    let isMerge: Bool
    var action: RebaseAction = .pick
    /// The new message, for a reword. Unused by every other action.
    var message: String = ""

    var id: String { return commit.sha }
}

// MARK: - Where it replays onto

enum RebaseBase: Hashable {
    case rev(String)
    /// The branch has no parent to replay onto: it starts at the first commit.
    case root

    var arguments: [String] {
        switch self {
        case .rev(let value): return [value]
        case .root: return ["--root"]
        }
    }

    var label: String {
        switch self {
        case .rev(let value): return String(value.prefix(20))
        case .root: return "the first commit"
        }
    }
}

// MARK: - The plan

struct RebasePlan: Hashable {
    let base: RebaseBase
    let branch: String
    /// Where HEAD was when the plan was read. Anything that moves the branch
    /// after that invalidates the plan: a commit the todo does not mention is a
    /// commit the replay would delete.
    let head: String
    /// There are older rewritable commits than the ones listed. The base is
    /// still the parent of the oldest one **listed**, so the ones left out are
    /// never touched.
    let truncated: Bool
    /// Oldest first, which is the order git replays them in.
    var steps: [RebaseStep]

    var kept: Int { return steps.filter { $0.action == .pick || $0.action == .reword }.count }
    var squashed: Int { return steps.filter { $0.action == .squash }.count }
    var dropped: Int { return steps.filter { $0.action == .drop }.count }
    /// The order the commits came in, so a reorder can be told from no change
    /// at all. Ids only: the steps themselves are mutated by the user.
    var originalIDs: [String] = []

    var isReordered: Bool { return steps.map { $0.id } != originalIDs }

    /// True when running this plan would actually do something.
    var changesAnything: Bool {
        if squashed > 0 || dropped > 0 { return true }
        if steps.contains(where: { $0.action == .reword }) { return true }
        return isReordered
    }

    var summary: String {
        let before = steps.count
        return before == kept
            ? "\(before) commit\(before == 1 ? "" : "s")"
            : "\(before) commit\(before == 1 ? "" : "s") \u{2192} \(kept)"
    }

    var actionSummary: String {
        var parts: [String] = []
        if squashed > 0 { parts.append("\(squashed) squashed") }
        if dropped > 0 { parts.append("\(dropped) dropped") }
        let reworded = steps.filter { $0.action == .reword }.count
        if reworded > 0 { parts.append("\(reworded) reworded") }
        if isReordered { parts.append("reordered") }
        return parts.isEmpty ? "no change" : parts.joined(separator: ", ")
    }

    /// Why this plan cannot run, or nil when it can.
    var problem: String? {
        guard !steps.isEmpty else { return "There is nothing to reorganize." }

        if let merge = steps.first(where: { $0.isMerge }) {
            return "\(merge.commit.shortSha) is a merge commit, and replaying the sequence would flatten it. This range cannot be reorganized."
        }
        if kept == 0 {
            return "Nothing would be left: at least one commit has to be kept."
        }

        // A squash needs a commit above it that survives, to fold into.
        var targetAbove = false
        for step in steps {
            switch step.action {
            case .squash:
                guard targetAbove else {
                    return "\(step.commit.shortSha) is set to squash, but there is no commit above it to fold into."
                }
            case .pick, .reword:
                targetAbove = true
            case .drop:
                break
            }
        }

        for step in steps where step.action == .reword {
            if step.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "\(step.commit.shortSha) is set to reword but its new message is empty."
            }
        }
        return nil
    }
}

// MARK: - The files git reads

/// Writes the todo list, and one file per new message, into a temporary
/// directory of its own. Nothing is written inside the user's repository.
struct RebaseScript {
    let directory: URL
    let todo: URL

    static func write(_ plan: RebasePlan) throws -> RebaseScript {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("git-agent-rebase-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var lines: [String] = []
        for (index, step) in plan.steps.enumerated() {
            let short = step.commit.shortSha
            // The subject is a comment to git, but it is what makes the file
            // readable if anyone ever looks at it.
            let subject = step.commit.subject.replacingOccurrences(of: "\n", with: " ")
            switch step.action {
            case .pick:
                lines.append("pick \(short) \(subject)")
            case .squash:
                // fixup, not squash: it keeps the message of the commit above
                // and never opens an editor. A different message is asked for
                // by rewording that commit instead.
                lines.append("fixup \(short) \(subject)")
            case .reword:
                let message = step.message.trimmingCharacters(in: .whitespacesAndNewlines)
                let file = directory.appendingPathComponent("message-\(index).txt")
                try message.write(to: file, atomically: true, encoding: .utf8)
                lines.append("pick \(short) \(subject)")
                // --cleanup=whitespace, not strip: strip removes comment lines,
                // and "#1234 fix the login bug" is an ordinary message that
                // would become empty and break the replay.
                lines.append("exec git commit --amend --cleanup=whitespace --file="
                             + GitRepository.singleQuoted(file.path))
            case .drop:
                lines.append("drop \(short) \(subject)")
            }
        }

        let todo = directory.appendingPathComponent("git-rebase-todo")
        try (lines.joined(separator: "\n") + "\n").write(to: todo, atomically: true, encoding: .utf8)
        return RebaseScript(directory: directory, todo: todo)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
