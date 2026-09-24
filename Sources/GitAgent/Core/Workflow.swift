import Foundation

// MARK: - What one step does

/// The operations a workflow can be built from. The user picks one of these
/// and fills in names; the argv is this app's, never a string anyone typed.
enum WorkflowStepKind: String, Codable, CaseIterable, Hashable, Identifiable {
    case checkout
    case pull
    case push
    case merge
    case fetch
    case rebase
    case createBranch
    case deleteBranch
    case stash
    case stashApply
    case stashPop
    case tag
    case cherryPick

    var id: String { return rawValue }

    var label: String {
        switch self {
        case .checkout: return "Checkout branch"
        case .pull: return "Pull"
        case .push: return "Push"
        case .merge: return "Merge branch"
        case .fetch: return "Fetch"
        case .rebase: return "Rebase"
        case .createBranch: return "Create branch"
        case .deleteBranch: return "Delete branch"
        case .stash: return "Stash"
        case .stashApply: return "Stash apply"
        case .stashPop: return "Stash pop"
        case .tag: return "Tag"
        case .cherryPick: return "Cherry-pick"
        }
    }

    /// The short word in a step row.
    var shortLabel: String {
        switch self {
        case .checkout: return "Checkout"
        case .pull: return "Pull"
        case .push: return "Push"
        case .merge: return "Merge"
        case .fetch: return "Fetch"
        case .rebase: return "Rebase"
        case .createBranch: return "Create branch"
        case .deleteBranch: return "Delete branch"
        case .stash: return "Stash"
        case .stashApply: return "Stash apply"
        case .stashPop: return "Stash pop"
        case .tag: return "Tag"
        case .cherryPick: return "Cherry-pick"
        }
    }

    var icon: String {
        switch self {
        case .checkout: return "arrow.triangle.branch"
        case .pull: return "arrow.down"
        case .push: return "arrow.up"
        case .merge: return "arrow.triangle.merge"
        case .fetch: return "arrow.down.circle"
        case .rebase: return "arrow.triangle.turn.up.right.diamond"
        case .createBranch: return "plus.circle"
        case .deleteBranch: return "minus.circle"
        case .stash: return "tray.and.arrow.down"
        case .stashApply, .stashPop: return "tray.and.arrow.up"
        case .tag: return "tag"
        case .cherryPick: return "checkmark.circle"
        }
    }

    /// Which fields the editor shows. Everything else stays off the screen.
    var usesBranch: Bool {
        switch self {
        case .checkout, .merge, .rebase, .createBranch, .deleteBranch, .tag, .cherryPick:
            return true
        case .pull, .push, .fetch, .stash, .stashApply, .stashPop:
            return false
        }
    }

    var usesRemote: Bool {
        switch self {
        case .pull, .push, .fetch: return true
        default: return false
        }
    }

    var usesText: Bool {
        switch self {
        case .stash, .tag: return true
        default: return false
        }
    }

    var usesRebaseToggle: Bool { return self == .pull }

    /// The label above the branch field, because "branch" means something
    /// different for a merge than for a checkout.
    var branchLabel: String {
        switch self {
        case .merge, .cherryPick: return "Source"
        case .rebase: return "Onto"
        case .createBranch: return "New branch"
        case .deleteBranch: return "Branch to delete"
        case .tag: return "Tag name"
        default: return "Branch"
        }
    }

    var textLabel: String {
        switch self {
        case .stash: return "Message"
        case .tag: return "Message (optional, makes it annotated)"
        default: return "Text"
        }
    }

    /// Writes to the remote, or can lose something. The review screen leads
    /// with these.
    var isWeighty: Bool {
        switch self {
        case .push, .merge, .rebase, .deleteBranch, .stashPop: return true
        default: return false
        }
    }

    var touchesRemote: Bool {
        switch self {
        case .pull, .push, .fetch: return true
        default: return false
        }
    }
}

// MARK: - Variables

enum WorkflowVariableKind: String, Codable, CaseIterable, Hashable, Identifiable {
    case branch
    case remote
    case text
    case branchList

    var id: String { return rawValue }

    var label: String {
        switch self {
        case .branch: return "Branch"
        case .remote: return "Remote"
        case .text: return "Text"
        case .branchList: return "Branches (list)"
        }
    }

    var isList: Bool { return self == .branchList }
}

/// A value the workflow asks for when it runs, instead of being nailed to one
/// branch forever.
struct WorkflowVariable: Identifiable, Codable, Hashable {
    var id = UUID()
    /// Referred to in a step as {{NAME}}.
    var name: String
    var kind: WorkflowVariableKind
    /// The value offered when the workflow runs.
    var value: String = ""
    /// For a list, the values offered, all ticked by default.
    var values: [String] = []

    var token: String { return "{{" + name + "}}" }
}

// MARK: - A step

struct WorkflowStep: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: WorkflowStepKind
    /// Branch, tag name or revision, depending on the kind. May be a {{TOKEN}}.
    var branch: String = ""
    var remote: String = ""
    /// Stash or tag message.
    var text: String = ""
    /// Pull only: rebase instead of merge.
    var rebase: Bool = false
    /// The name of a list variable. Steps that sit next to each other and name
    /// the same list repeat together, once per value, with {{EACH}} bound to
    /// it. That is what turns four steps into "for dev, then for master".
    var repeatFor: String = ""

    var repeats: Bool { return !repeatFor.isEmpty }
}

// MARK: - The workflow

struct GitWorkflow: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var detail: String = ""
    var variables: [WorkflowVariable] = []
    var steps: [WorkflowStep] = []
    var createdAt = Date()
    var updatedAt = Date()

    /// "release \u{2192} dev \u{2192} master", from the variables when they say
    /// so, and from the checkouts when they do not.
    func flowLabel(values: WorkflowValues? = nil) -> String {
        let source = variables.first { $0.kind == .branch }
        let targets = variables.first { $0.kind == .branchList }

        var parts: [String] = []
        if let source {
            let resolved = values?.single[source.name] ?? source.value
            if !resolved.isEmpty { parts.append(resolved) }
        }
        if let targets {
            let chosen = values?.selected[targets.name] ?? targets.values
            parts.append(contentsOf: chosen)
        }
        if parts.count > 1 { return parts.joined(separator: " \u{2192} ") }

        // No variables: read the branches the steps check out.
        var seen: [String] = []
        for step in steps where step.kind == .checkout || step.kind == .createBranch {
            let name = step.branch.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !seen.contains(name) { seen.append(name) }
        }
        return seen.isEmpty ? "\(steps.count) step\(steps.count == 1 ? "" : "s")" : seen.joined(separator: " \u{2192} ")
    }

    var stepCountLabel: String {
        return steps.count == 1 ? "1 step" : "\(steps.count) steps"
    }

    /// The values a run starts from.
    func defaultValues() -> WorkflowValues {
        var single: [String: String] = [:]
        var selected: [String: [String]] = [:]
        for variable in variables {
            if variable.kind.isList {
                selected[variable.name] = variable.values
            } else {
                single[variable.name] = variable.value
            }
        }
        return WorkflowValues(single: single, selected: selected)
    }
}

/// What one run was given.
struct WorkflowValues: Codable, Hashable {
    var single: [String: String] = [:]
    var selected: [String: [String]] = [:]
}

// MARK: - Expanding into commands

/// One step as it will actually run: after substitution, after the repeats
/// were unrolled, with the argv already built.
struct ResolvedStep: Identifiable, Hashable {
    let id = UUID()
    let kind: WorkflowStepKind
    /// "Merge release \u{2192} dev"
    let title: String
    let arguments: [String]
    /// The value of the list this step was repeated for, when it was.
    let each: String?

    var display: String { return "git " + arguments.joined(separator: " ") }
}

/// What expanding a step produced. Swift's `Result` requires its failure to be
/// an `Error`, and what fails here is a sentence for the user, not a thrown
/// condition, so it carries the sentence.
enum WorkflowExpansion<Value> {
    case success(Value)
    case failure(String)
}

enum WorkflowExpander {

    /// Substitutes, unrolls the repeats and builds the argv. Returns the
    /// reason instead when the workflow cannot be turned into commands.
    static func expand(_ workflow: GitWorkflow,
                       values: WorkflowValues,
                       currentBranch: String) -> WorkflowExpansion<[ResolvedStep]> {
        var result: [ResolvedStep] = []
        var index = 0
        // Where HEAD will be by the time each step runs. Titles are read as a
        // promise, so "Merge release \u{2192} dev" has to mean the commands
        // really put HEAD on dev first.
        var head = currentBranch

        while index < workflow.steps.count {
            let step = workflow.steps[index]

            guard step.repeats else {
                switch resolve(step, values: values, each: nil, head: head) {
                case .failure(let why): return .failure(why)
                case .success(let pair):
                    result.append(pair.0)
                    head = pair.1
                }
                index += 1
                continue
            }

            // Consecutive steps naming the same list are one block, and the
            // block repeats: checkout, pull, merge, push for dev; then the
            // same for master. Interleaving them would be nonsense.
            let listName = step.repeatFor
            var block: [WorkflowStep] = []
            while index < workflow.steps.count, workflow.steps[index].repeatFor == listName {
                block.append(workflow.steps[index])
                index += 1
            }

            guard let chosen = values.selected[listName] else {
                return .failure("\(block.count) step\(block.count == 1 ? "" : "s") repeat for \u{201c}\(listName)\u{201d}, which is not a list this workflow has.")
            }
            guard !chosen.isEmpty else {
                return .failure("\(listName) has nothing selected, and \(block.count) step\(block.count == 1 ? "" : "s") repeat for it.")
            }
            for value in chosen where !isSafeName(value) {
                return .failure("\u{201c}\(value)\u{201d} in \(listName) is not a name git can take.")
            }
            for value in chosen {
                for inner in block {
                    switch resolve(inner, values: values, each: value, head: head) {
                    case .failure(let why): return .failure(why)
                    case .success(let pair):
                        result.append(pair.0)
                        head = pair.1
                    }
                }
            }
        }

        guard !result.isEmpty else { return .failure("This workflow has no steps.") }
        return .success(result)
    }

    /// Returns the step and where HEAD stands after it.
    private static func resolve(_ step: WorkflowStep,
                                values: WorkflowValues,
                                each: String?,
                                head: String) -> WorkflowExpansion<(ResolvedStep, String)> {
        let branch = substitute(step.branch, values: values, each: each)
        let remote = substitute(step.remote, values: values, each: each)
        let text = substitute(step.text, values: values, each: each)

        if step.kind.usesBranch {
            guard !branch.isEmpty else {
                return .failure("\(step.kind.label) has no \(step.kind.branchLabel.lowercased()).")
            }
            guard isSafeName(branch) else {
                return .failure("\u{201c}\(branch)\u{201d} is not a name git can take here.")
            }
        }
        if !remote.isEmpty, !isSafeName(remote) {
            return .failure("\u{201c}\(remote)\u{201d} is not a remote name.")
        }

        let arguments = command(step.kind, branch: branch, remote: remote, text: text, rebase: step.rebase)
        let title = describe(step.kind, branch: branch, remote: remote, head: head)
        let moved = (step.kind == .checkout || step.kind == .createBranch) ? branch : head
        return .success((ResolvedStep(kind: step.kind, title: title, arguments: arguments, each: each), moved))
    }

    /// {{NAME}} for a variable, {{EACH}} for the value of the repeat.
    static func substitute(_ value: String, values: WorkflowValues, each: String?) -> String {
        var text = value
        if let each { text = text.replacingOccurrences(of: "{{EACH}}", with: each) }
        // Longest name first, and in a fixed order: iterating a Dictionary is
        // unordered, so the same workflow could otherwise expand differently
        // from one launch to the next.
        for name in values.single.keys.sorted(by: { ($0.count, $0) > ($1.count, $1) }) {
            guard let replacement = values.single[name] else { continue }
            text = text.replacingOccurrences(of: "{{" + name + "}}", with: replacement)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// A branch, tag or remote name, and nothing that could be read as an
    /// option or a refspec.
    static func isSafeName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200 else { return false }
        guard !value.hasPrefix("-"), !value.hasPrefix("/"), !value.hasPrefix(".") else { return false }
        guard !value.contains(".."), !value.contains(":"), !value.contains("+") else { return false }
        for character in value {
            guard character.isASCII, !character.isWhitespace else { return false }
            let allowed = character.isLetter || character.isNumber
                || "._-/~^@".contains(character)
            guard allowed else { return false }
        }
        return true
    }

    /// The argv, from a fixed template. The user fills names, never flags.
    static func command(_ kind: WorkflowStepKind,
                        branch: String,
                        remote: String,
                        text: String,
                        rebase: Bool) -> [String] {
        switch kind {
        case .checkout:
            return ["switch", branch]
        case .createBranch:
            return ["switch", "-c", branch]
        case .pull:
            var arguments = ["pull"]
            if rebase { arguments.append("--rebase") }
            if !remote.isEmpty { arguments.append(remote) }
            return arguments
        case .push:
            // HEAD, always: a bare "git push origin" does whatever
            // push.default says, and on "matching" that publishes every
            // branch whose name exists on the remote.
            if remote.isEmpty { return ["push"] }
            return ["push", remote, "HEAD"]
        case .fetch:
            var arguments = ["fetch"]
            if !remote.isEmpty { arguments.append(remote) }
            return arguments
        case .merge:
            return ["merge", "--no-edit", branch]
        case .rebase:
            return ["rebase", branch]
        case .deleteBranch:
            // -d, never -D: git refuses to drop a branch that is not merged.
            return ["branch", "-d", branch]
        case .stash:
            var arguments = ["stash", "push", "--include-untracked"]
            if !text.isEmpty { arguments.append(contentsOf: ["-m", text]) }
            return arguments
        case .stashApply:
            return ["stash", "apply"]
        case .stashPop:
            return ["stash", "pop"]
        case .tag:
            if text.isEmpty { return ["tag", branch] }
            return ["tag", "-a", branch, "-m", text]
        case .cherryPick:
            return ["cherry-pick", branch]
        }
    }

    static func describe(_ kind: WorkflowStepKind,
                         branch: String,
                         remote: String,
                         head: String) -> String {
        let here = head.isEmpty ? "the current branch" : head
        switch kind {
        case .checkout: return "Checkout " + branch
        case .createBranch: return "Create " + branch
        case .pull: return remote.isEmpty ? "Pull " + here : "Pull \(remote)/\(here)"
        case .push: return remote.isEmpty ? "Push " + here : "Push \(remote)/\(here)"
        case .fetch: return remote.isEmpty ? "Fetch" : "Fetch " + remote
        case .merge: return "Merge \(branch) \u{2192} \(here)"
        case .rebase: return "Rebase \(here) onto \(branch)"
        case .deleteBranch: return "Delete " + branch
        case .stash: return "Stash changes"
        case .stashApply: return "Apply the latest stash"
        case .stashPop: return "Pop the latest stash"
        case .tag: return "Tag " + branch
        case .cherryPick: return "Cherry-pick " + branch
        }
    }
}

// MARK: - The example

enum WorkflowLibrary {

    /// The workflow the feature is explained by: the nine commands everyone
    /// types by hand, as five steps that repeat for each target.
    static func promoteRelease() -> GitWorkflow {
        let source = WorkflowVariable(name: "SOURCE", kind: .branch, value: "release")
        let targets = WorkflowVariable(name: "TARGETS", kind: .branchList, values: ["dev", "master"])
        let remote = WorkflowVariable(name: "REMOTE", kind: .remote, value: "origin")

        var steps: [WorkflowStep] = []
        steps.append(WorkflowStep(kind: .checkout, branch: "{{EACH}}", repeatFor: "TARGETS"))
        steps.append(WorkflowStep(kind: .pull, remote: "{{REMOTE}}", repeatFor: "TARGETS"))
        steps.append(WorkflowStep(kind: .merge, branch: "{{SOURCE}}", repeatFor: "TARGETS"))
        steps.append(WorkflowStep(kind: .push, remote: "{{REMOTE}}", repeatFor: "TARGETS"))
        steps.append(WorkflowStep(kind: .checkout, branch: "{{SOURCE}}"))

        return GitWorkflow(name: "Promote Release",
                           detail: "Promote a release through environments, then come back to it.",
                           variables: [source, targets, remote],
                           steps: steps)
    }
}
