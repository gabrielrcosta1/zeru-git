import Foundation
import SwiftUI

/// Everything a workflow needs to exist, be edited, be checked, and be run.
///
/// It is one object rather than a pile of state on the session because a
/// workflow is a composed operation: the configuration, the variables, the
/// checks, the run and its history are the same thing at different moments.
@MainActor
final class WorkflowEngine: ObservableObject {

    // The library
    @Published private(set) var workflows: [GitWorkflow] = []
    @Published private(set) var runs: [WorkflowRun] = []
    @Published private(set) var loaded = false
    @Published var problem: String?

    // Editing
    @Published var draft: GitWorkflow?
    @Published private(set) var draftIsNew = false

    // Preparing and running
    @Published var prepared: PreparedRun?
    /// The run on screen while it happens. The loop keeps its own copy: this
    /// one is for showing, and clearing it must never lose the record of git
    /// commands that already changed the repository.
    @Published private(set) var activeRun: WorkflowRun?
    @Published private(set) var running = false
    /// The step whose output is open, in whichever run is on screen.
    @Published var openStep: UUID?
    /// A run from the history, when one is being looked at.
    @Published var historyRun: WorkflowRun?

    private let store: WorkflowStore
    private let repository: GitRepository
    weak var session: ProjectSession?
    private var task: Task<Void, Never>?

    init(root: URL, repository: GitRepository) {
        self.store = WorkflowStore(root: root)
        self.repository = repository
    }

    func teardown() {
        task?.cancel()
        task = nil
    }

    // MARK: - The library

    func load() async {
        guard !loaded else { return }
        let contents = await store.load()
        workflows = contents.workflows
        runs = contents.runs
        loaded = true

        if contents.unreadable {
            // An empty library because the file could not be read is not an
            // empty library. Seeding on top of that would write over it.
            problem = "The saved workflows could not be read. They have been set aside as workflows-unreadable.json rather than written over."
            return
        }
        // Nothing to look at is a bad first impression for a feature that is
        // best explained by an example.
        if workflows.isEmpty {
            workflows = [WorkflowLibrary.promoteRelease()]
            await persistWorkflows()
        }
    }

    func runs(of workflow: GitWorkflow) -> [WorkflowRun] {
        return runs.filter { $0.workflowID == workflow.id }.sorted { $0.startedAt > $1.startedAt }
    }

    func lastRun(of workflow: GitWorkflow) -> WorkflowRun? {
        return runs(of: workflow).first
    }

    private func persistWorkflows() async {
        let saved = await store.save(workflows: workflows)
        if !saved {
            problem = "The workflows could not be written to disk, so they will be gone when the app quits."
        }
    }

    // MARK: - Editing

    func beginCreate() {
        draft = GitWorkflow(name: "", detail: "")
        draftIsNew = true
        problem = nil
        session?.openWorkflowEditor()
    }

    func beginEdit(_ workflow: GitWorkflow) {
        draft = workflow
        draftIsNew = false
        problem = nil
        session?.openWorkflowEditor()
    }

    func cancelEdit() {
        draft = nil
        session?.openWorkflows()
    }

    /// Why the draft cannot be saved, or nil.
    var draftProblem: String? {
        guard let draft else { return nil }
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give the workflow a name."
        }
        if draft.steps.isEmpty { return "A workflow needs at least one step." }
        for step in draft.steps where step.kind.usesBranch {
            if step.branch.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Step \(step.kind.shortLabel) has no \(step.kind.branchLabel.lowercased())."
            }
        }
        var seen = Set<String>()
        for variable in draft.variables {
            let name = variable.name.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { return "A variable has no name." }
            if name == "EACH" {
                return "{{EACH}} is the value of a repeat, so a variable cannot be called EACH."
            }
            guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
                return "\u{201c}\(name)\u{201d} can only use letters, numbers and underscores."
            }
            if !seen.insert(name).inserted {
                return "Two variables are called \u{201c}\(name)\u{201d}."
            }
            if variable.kind.isList {
                if variable.values.isEmpty { return "\(name) is a list with nothing in it." }
                for value in variable.values where value.trimmingCharacters(in: .whitespaces).isEmpty {
                    return "\(name) has an empty entry."
                }
            }
        }

        let lists = Set(draft.variables.filter { $0.kind.isList }.map { $0.name })
        for step in draft.steps where step.repeats {
            if !lists.contains(step.repeatFor) {
                return "A step repeats for \u{201c}\(step.repeatFor)\u{201d}, which is not a list variable."
            }
        }
        return nil
    }

    func saveDraft() async {
        guard var draft else { return }
        if let reason = draftProblem {
            problem = reason
            return
        }
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.updatedAt = Date()
        if let index = workflows.firstIndex(where: { $0.id == draft.id }) {
            workflows[index] = draft
        } else {
            workflows.append(draft)
        }
        self.draft = nil
        problem = nil
        await persistWorkflows()
        session?.openWorkflows()
    }

    func duplicate(_ workflow: GitWorkflow) async {
        var copy = workflow
        copy.id = UUID()
        copy.name = workflow.name + " copy"
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.steps = workflow.steps.map { step in
            var value = step
            value.id = UUID()
            return value
        }
        copy.variables = workflow.variables.map { variable in
            var value = variable
            value.id = UUID()
            return value
        }
        workflows.append(copy)
        await persistWorkflows()
    }

    func delete(_ workflow: GitWorkflow) async {
        workflows.removeAll { $0.id == workflow.id }
        runs = await store.removeRuns(ofWorkflow: workflow.id)
        if prepared?.workflow.id == workflow.id { prepared = nil }
        await persistWorkflows()
    }

    // MARK: - Preparing a run

    /// Works out the commands, checks the repository, and opens the review.
    func prepare(_ workflow: GitWorkflow) async {
        guard !running else {
            problem = "A workflow is running. Wait for it to finish."
            return
        }
        problem = nil
        historyRun = nil
        activeRun = nil
        var values = workflow.defaultValues()
        // A branch variable with no value defaults to where the user is.
        if let state = session?.repo {
            for variable in workflow.variables where variable.kind == .branch {
                if (values.single[variable.name] ?? "").isEmpty {
                    values.single[variable.name] = state.branchLabel
                }
            }
        }
        prepared = PreparedRun(workflow: workflow, values: values, steps: [], checks: [], problem: nil)
        await revalidate()
        session?.openWorkflowRun()
    }

    func setValue(_ value: String, for name: String) {
        guard prepared != nil else { return }
        prepared?.values.single[name] = value
        Task { await revalidate() }
    }

    func toggleTarget(_ value: String, in name: String) {
        guard var current = prepared else { return }
        var chosen = current.values.selected[name] ?? []
        if let index = chosen.firstIndex(of: value) {
            chosen.remove(at: index)
        } else {
            // Keep the order the workflow declared, not the order of clicks.
            let order = current.workflow.variables.first { $0.name == name }?.values ?? []
            chosen.append(value)
            chosen.sort { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
        }
        current.values.selected[name] = chosen
        prepared = current
        Task { await revalidate() }
    }

    /// Rebuilds the commands and the checks from the values as they stand.
    func revalidate() async {
        guard var current = prepared else { return }
        let branch = session?.repo?.branchLabel ?? ""

        switch WorkflowExpander.expand(current.workflow, values: current.values, currentBranch: branch) {
        case .failure(let why):
            current.steps = []
            current.problem = why
        case .success(let steps):
            current.steps = steps
            current.problem = nil
        }
        current.checks = await checks(for: current)
        // Only the derived fields go back. The user may have ticked another
        // target while the checks were running, and assigning the whole struct
        // would put the values back as they were before the tick.
        prepared?.steps = current.steps
        prepared?.problem = current.problem
        prepared?.checks = current.checks
    }

    private func checks(for prepared: PreparedRun) async -> [WorkflowCheck] {
        var result: [WorkflowCheck] = []

        guard let session, let state = session.repo else {
            return [WorkflowCheck(title: "Repository available", passed: false,
                                  detail: "The project is still loading.")]
        }
        result.append(WorkflowCheck(title: "Repository available", passed: true, detail: nil))

        let dirty = state.hasChanges
        result.append(WorkflowCheck(title: "Working tree clean",
                                    passed: !dirty && !state.hasConflicts && !state.isMerging && !state.isRebasing,
                                    detail: dirty
                                        ? "\(state.changes.count) uncommitted change\(state.changes.count == 1 ? "" : "s"). Commit or stash them first."
                                        : (state.hasConflicts ? "There are conflicts to resolve."
                                           : (state.isMerging || state.isRebasing ? "A merge or rebase is in progress." : nil))))

        if prepared.steps.contains(where: { $0.kind.touchesRemote }) {
            let remote = await repository.remoteURL()
            result.append(WorkflowCheck(title: "Remote available",
                                        passed: remote != nil,
                                        detail: remote == nil ? "This repository has no origin, and a step talks to the remote." : nil))
        }

        // The branch list is loaded lazily, and an empty one is not the same
        // as a repository with no branches: without this the check reported
        // every branch of the workflow as missing, the current one included.
        if session.branches.isEmpty { await session.loadBranches() }
        let known = Set(session.branches.flatMap { [$0.name, $0.localName] })
        guard !known.isEmpty else {
            // Still nothing: say what is not known rather than inventing a
            // failure the user cannot act on.
            result.append(WorkflowCheck(title: "Branches exist",
                                        passed: true,
                                        detail: "The branch list could not be read, so the names were not checked."))
            return result
        }

        // Every branch a step names has to be there, except the one a create
        // step is about to make, which must not be.
        var missing: [String] = []
        var existing: [String] = []
        for step in prepared.steps {
            guard let name = branchName(of: step) else { continue }
            switch step.kind {
            case .createBranch:
                if known.contains(name) { existing.append(name) }
            case .tag:
                // git takes "tag master" happily and leaves every later
                // reference to master ambiguous.
                if known.contains(name) { existing.append(name) }
            case .checkout, .merge, .rebase, .cherryPick, .deleteBranch:
                if !known.contains(name), !isRevisionish(name) { missing.append(name) }
            default:
                break
            }
        }
        if !missing.isEmpty {
            let unique = Array(Set(missing)).sorted()
            result.append(WorkflowCheck(title: "Branches exist",
                                        passed: false,
                                        detail: "Not in this repository: " + unique.joined(separator: ", ") + ". Fetch, or pick another branch."))
        } else {
            result.append(WorkflowCheck(title: "Branches exist", passed: true, detail: nil))
        }
        if !existing.isEmpty {
            let unique = Array(Set(existing)).sorted()
            result.append(WorkflowCheck(title: "New branches are free",
                                        passed: false,
                                        detail: "A branch of that name is already there: " + unique.joined(separator: ", ") + "."))
        }
        return result
    }

    private func branchName(of step: ResolvedStep) -> String? {
        // The argv is built by this app, so the name sits at a known place.
        switch step.kind {
        case .checkout, .merge, .rebase, .cherryPick:
            return step.arguments.last
        case .createBranch, .deleteBranch:
            return step.arguments.last
        case .tag:
            // "tag <name>" or "tag -a <name> -m <message>".
            return step.arguments.count > 2 ? step.arguments[2] : step.arguments.last
        default:
            return nil
        }
    }

    /// "HEAD~1" and a sha are not branches, and asking whether they are a
    /// branch would fail them wrongly.
    private func isRevisionish(_ name: String) -> Bool {
        if name.contains("~") || name.contains("^") || name.contains("@") { return true }
        if name.count >= 7, name.allSatisfy({ $0.isHexDigit }) { return true }
        return name.uppercased() == "HEAD"
    }

    // MARK: - Running

    var canExecute: Bool {
        guard let prepared, !running else { return false }
        return prepared.canRun
    }

    func execute() async {
        guard let prepared, prepared.canRun, !running else { return }
        guard session?.isBusy != true else {
            problem = "Something else is running in this project. Wait for it to finish."
            return
        }

        var run = WorkflowRun(workflowID: prepared.workflow.id,
                              workflowName: prepared.workflow.name,
                              flowLabel: prepared.workflow.flowLabel(values: prepared.values))
        run.steps = prepared.steps.map { step in
            WorkflowRunStep(kind: step.kind,
                            title: step.title,
                            command: step.display,
                            each: step.each)
        }
        activeRun = run
        historyRun = nil
        running = true
        openStep = nil
        // The whole app treats this as busy: git serialises the processes, but
        // it does not order them, and a branch switch landing between two
        // steps would put the next merge on the wrong branch.
        session?.phase = .runningWorkflow
        session?.log(.info, "Workflow \u{201c}\(run.workflowName)\u{201d} started \u{00b7} \(run.steps.count) steps")

        let steps = prepared.steps
        let headBefore = await repository.head()
        var failed = false

        for (index, step) in steps.enumerated() {
            if Task.isCancelled { break }
            run.steps[index].state = .running
            activeRun = run

            let started = Date()
            do {
                let output = try await repository.runStep(step.arguments, timeout: 300)
                run.steps[index].state = .done
                run.steps[index].duration = Date().timeIntervalSince(started)
                run.steps[index].output = output.trimmingCharacters(in: .whitespacesAndNewlines)
                activeRun = run
                session?.log(.tool, step.display)
            } catch {
                let described = GitFailure.describe(error)
                run.steps[index].state = .failed
                run.steps[index].duration = Date().timeIntervalSince(started)
                run.steps[index].output = described.full
                run.outcome = .failed
                run.problem = described.message
                session?.log(.failure, "Workflow stopped at \(step.title): \(described.message)")
                failed = true
                break
            }
        }

        // Whatever did not run says so, rather than sitting as "waiting"
        // forever in the history.
        for index in run.steps.indices where run.steps[index].state == .pending {
            run.steps[index].state = .skipped
        }

        if !failed {
            let stopped = run.steps.contains { $0.state == .skipped }
            if stopped {
                run.outcome = .aborted
                run.problem = "Stopped before the end."
                session?.log(.warning, "Workflow \u{201c}\(run.workflowName)\u{201d} aborted")
            } else {
                run.outcome = .completed
                session?.log(.success, "Workflow \u{201c}\(run.workflowName)\u{201d} finished in \(run.durationLabel)")
            }
        }
        run.finishedAt = Date()
        activeRun = run
        await finish(run: run, headBefore: headBefore)
    }

    /// Stops before the next step. A git command already in flight is left to
    /// finish: killing it half way is how a repository ends up in a state
    /// nobody asked for.
    func abort() {
        guard running else { return }
        task?.cancel()
        session?.log(.warning, "Workflow will stop after the running step")
    }

    func start() {
        // Cancelling a task that has not begun would make the next one stop at
        // its first step and record an abort that never ran anything.
        guard !running, task == nil else { return }
        task = Task { @MainActor [weak self] in
            await self?.execute()
            self?.task = nil
        }
    }

    /// Takes the run by value: it is the record of commands that already
    /// happened, and it must not depend on a published property still holding
    /// it by the time this runs.
    private func finish(run: WorkflowRun, headBefore: String?) async {
        running = false
        if session?.phase == .runningWorkflow { session?.phase = .ready }
        let saved = await store.save(run: run)
        runs = saved.runs
        if !saved.saved {
            problem = "This run could not be written to the history on disk."
        }
        await session?.recordWorkflow(run, headBefore: headBefore)
        // The branch, the graph, the status and the history all moved.
        await session?.refreshAfterWorkflow()
    }

    // MARK: - History

    func open(run: WorkflowRun) {
        guard !running else { return }
        historyRun = run
        activeRun = nil
        openStep = nil
        session?.openWorkflowRun()
    }

    /// Whichever run the run panel should be showing.
    var visibleRun: WorkflowRun? { return activeRun ?? historyRun }

    /// Closes the run panel. Refused while a run is in flight: the panel is
    /// the only place the abort button lives.
    func closeRun() {
        guard !running else { return }
        activeRun = nil
        historyRun = nil
        prepared = nil
        openStep = nil
    }
}

// MARK: - A run being prepared

struct PreparedRun {
    let workflow: GitWorkflow
    var values: WorkflowValues
    var steps: [ResolvedStep]
    var checks: [WorkflowCheck]
    /// Why the steps could not be worked out at all.
    var problem: String?

    var failedChecks: [WorkflowCheck] { return checks.filter { !$0.passed } }
    var canRun: Bool { return problem == nil && !steps.isEmpty && failedChecks.isEmpty }

    var weightySteps: [ResolvedStep] { return steps.filter { $0.kind.isWeighty } }
}
