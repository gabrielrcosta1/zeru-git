import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - Phases

enum AppPhase: Equatable {
    case noProject
    case loadingProject
    case ready
    case reviewing
    case fixing
    case verifying
    case committing
    case pushing
    case switchingBranch
    case pulling
    case stashing
    case resolvingConflicts
    case recovering
    case rebasing
    case applyingPlan
    case runningWorkflow
    case answering
    case syncing
}

enum ActivityKind {
    case info
    case tool
    case agent
    case warning
    case success
    case failure
}

/// The Activity panel shows two things: what happened to the repository, and
/// the raw log of what the app and the agent did to get there.
enum ActivityMode: String, CaseIterable, Hashable {
    case timeline
    case log

    var label: String {
        switch self {
        case .timeline: return "Timeline"
        case .log: return "Log"
        }
    }
}

struct ActivityLine: Identifiable {
    let id = UUID()
    let date = Date()
    let kind: ActivityKind
    let text: String

    var time: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// A git lock is in the way. The user decides what happens next.
struct LockAlert: Identifiable {
    let id = UUID()
    let detail: String
    let lockPath: String?
    let canRemove: Bool
    /// Processes the app itself started and may therefore stop.
    let stoppable: [Int32]
    let retry: () async -> Void
}

/// A branch switch git refused because untracked files would be written over.
struct BlockedSwitch: Identifiable {
    let id = UUID()
    let branch: GitBranch
    /// What git listed as being in the way.
    let paths: [String]

    var title: String {
        return paths.count == 1
            ? "One file is in the way"
            : "\(paths.count) files are in the way"
    }

    var message: String {
        let names = paths.prefix(6).joined(separator: "\n")
        let rest = paths.count > 6 ? "\n\u{2026} and \(paths.count - 6) more" : ""
        return """
        These files are not in git, and \(branch.localName) has its own version of them:

        \(names)\(rest)

        Git Agent can move them into the stash and switch. Nothing is deleted \u{2014} they stay in the stash until you pop them.
        """
    }
}

/// One confirmation for one or many files. Files that are not in any commit yet
/// go to the Trash (recoverable); tracked files are restored from HEAD.
struct DiscardRequest: Identifiable {
    let id = UUID()
    let changes: [FileChange]

    var trashed: [FileChange] {
        return changes.filter { $0.status == .untracked || $0.status == .added }
    }
    var restored: [FileChange] {
        return changes.filter { !($0.status == .untracked || $0.status == .added) }
    }

    var title: String {
        if changes.count == 1 { return "Discard changes?" }
        return "Discard \(changes.count) files?"
    }

    var confirmTitle: String {
        if restored.isEmpty { return trashed.count == 1 ? "Move to Trash" : "Move \(trashed.count) to Trash" }
        if changes.count == 1 { return "Discard" }
        return "Discard \(changes.count) files"
    }

    var message: String {
        var parts: [String] = []
        if !restored.isEmpty {
            let names = restored.count <= 3
                ? restored.map { $0.path }.joined(separator: ", ")
                : "\(restored.count) tracked files"
            parts.append("Every uncommitted change in \(names) will be restored to the last commit. This cannot be undone.")
        }
        if !trashed.isEmpty {
            let names = trashed.count <= 3
                ? trashed.map { $0.path }.joined(separator: ", ")
                : "\(trashed.count) files"
            parts.append("\(names) are not in any commit yet, so they go to the Trash. You can still recover them from there.")
        }
        return parts.joined(separator: "\n\n")
    }
}

struct PushRequest: Identifiable {
    let id = UUID()
    let branch: String
    let commitSubject: String
    let setUpstream: Bool
    var ahead: Int = 0
    var behind: Int = 0
}

/// The one action the repository is asking for next.
enum PrimaryAction: Equatable {
    case resolveConflicts(Int)
    case commitAndPush(files: Int)
    case push(commits: Int)
    case upToDate

    var title: String {
        switch self {
        case .resolveConflicts(let count):
            return count == 1 ? "1 conflict to resolve" : "\(count) conflicts to resolve"
        case .commitAndPush:
            return "Commit & Push"
        case .push(let count):
            return count == 1 ? "Push 1 commit" : "Push \(count) commits"
        case .upToDate:
            return "Up to date"
        }
    }

    var icon: String? {
        switch self {
        case .resolveConflicts: return "exclamationmark.triangle.fill"
        case .commitAndPush: return "arrow.up"
        case .push: return "arrow.up"
        case .upToDate: return "checkmark"
        }
    }

    var isEnabled: Bool {
        switch self {
        case .upToDate, .resolveConflicts: return false
        default: return true
        }
    }
}

/// What the expanded panel is showing. `nil` keeps the window compact.
enum DetailTarget: Equatable {
    case allChanges
    case file(String)
    case problem(UUID)
    case conflict(String)
    case activity
    case stashes
    case recovery
    case rebase
    case forge
    case plan
    case workflows
    case workflowEditor
    case workflowRun
    case chat
    case sync
    case commit(String)

    /// A panel that exists in every project, so it can follow a tab switch.
    /// A file, a conflict or an AI finding belongs to one project only.
    var isProjectIndependent: Bool {
        switch self {
        case .allChanges, .activity, .stashes, .recovery, .rebase, .forge, .workflows, .chat, .sync:
            return true
        case .file, .conflict, .problem, .commit, .plan,
             .workflowEditor, .workflowRun:
            return false
        }
    }
}

// MARK: - State

/// One open project. Everything in here belongs to that project alone: its
/// repository, file watcher, agent, review, commit message and detail panel.
@MainActor
final class ProjectSession: ObservableObject, Identifiable {

    let id = UUID()
    let root: URL

    /// Shared with every other tab.
    let settings: AppSettings
    weak var workspace: Workspace?

    // Project
    @Published var phase: AppPhase = .noProject
    @Published var repo: RepoState?
    @Published var projectName = ""

    // Selection and diff
    @Published var selectedPath: String?
    @Published var fileDiff: FileDiff?
    @Published var diffTitle = "All changes"
    @Published var loadingDiff = false

    // Activity
    /// Oldest first, the order the timeline groups on.
    @Published var timeline: [OperationRecord] = []

    // AI
    @Published var review: ReviewResult?
    @Published var agentActivity: [ActivityLine] = []
    @Published var agentBusyLabel: String?
    @Published var lastAgentReport: String?
    @Published var touchedFiles: [String] = []

    // Commit
    @Published var commitMessage = ""
    @Published var generatingMessage = false

    // Feedback
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var pushRequest: PushRequest?
    @Published var pendingDiscard: DiscardRequest?
    @Published var lockAlert: LockAlert?
    @Published var pushProblem: String?
    @Published var fetching = false
    @Published var pushSeconds = 0
    @Published var reviewError: String?

    // Inline diff, independent from the expanded panel
    @Published var inlinePath: String?
    @Published var inlineDiff: FileDiff?
    @Published var loadingInline = false

    // Stash
    @Published var stashCount = 0
    @Published var stashes: [GitStashEntry] = []
    /// One read has come back, successfully or not. Until then the panel says
    /// it is still looking instead of claiming the stash is empty.
    @Published var stashesLoaded = false
    @Published var stashReadFailed = false
    /// The sha of the entry whose diff is open, never its ref: dropping an
    /// entry renumbers every ref below it.
    @Published var expandedStash: String?
    @Published var stashDiff: FileDiff?
    @Published var loadingStashDiff = false
    @Published var pendingStashDrop: GitStashEntry?

    // The last git failure, ready to hand to the agent
    @Published var failure: AIFailure?
    @Published var plan: GitCommandPlan?
    /// What the user asked, when the plan came from the chat rather than from
    /// a failure. The plan panel reads it instead of naming a command that
    /// never failed.
    @Published var planQuestion: String?
    @Published var chat: [ChatMessage] = []
    /// A switch git refused because untracked files were in the way.
    @Published var blockedSwitch: BlockedSwitch?
    @Published var chatDraft = ""
    /// The one step waiting for the user to confirm it.
    @Published var pendingStep: GitCommandStep?
    @Published var runningPlan = false

    // Interactive rebase
    @Published var rebasePlan: RebasePlan?
    @Published var loadingRebase = false
    /// Why there is nothing to reorganize, when there is nothing.
    @Published var rebaseNote: String?
    /// Why the plan as it stands cannot run.
    @Published var rebaseProblem: String?
    @Published var pendingRebase: RebasePlan?

    // GitHub / GitLab, through the CLI the user already authenticated
    @Published var forge: ForgeInfo?
    /// Where this repository lives on the web. Read from the remote alone, so
    /// it is there whether or not gh is installed.
    @Published private(set) var web: ForgeWeb?
    @Published var forgeChecked = false
    @Published var forgePR: ForgePullRequest?
    @Published var forgePRs: [ForgePullRequest] = []
    @Published var forgeIssues: [ForgeIssue] = []
    @Published var loadingForge = false
    @Published var forgeError: String?
    private var forgeLoadedFor: String?
    /// Kept while a rebase this app started is still in progress: the todo it
    /// wrote names its message files by path.
    private var liveRebaseScript: RebaseScript?

    // Search
    @Published var searchResults: [SearchHit] = []
    @Published var searching = false
    /// Path and its lowercased form, so a keystroke does not lowercase the
    /// whole file list again.
    private var trackedFiles: [(path: String, lower: String)] = []
    private var trackedFilesAt: Date?
    private var searchTask: Task<Void, Never>?

    // One commit, opened from the palette
    @Published var commitDetail: GitCommit?
    @Published var commitDiff: FileDiff?
    @Published var loadingCommitDiff = false

    // Recovery
    @Published var recoveryPoints: [RecoveryPoint] = []
    @Published var loadingRecovery = false
    @Published var recoveryLoaded = false
    /// The loss the banner is offering to undo, when there is one.
    @Published var recoveryBanner: RecoveryPoint?
    @Published var pendingRecoveryReset: RecoveryPoint?
    /// The reflog could not be read. Not the same as a branch that never moved.
    @Published var recoveryReadFailed = false
    /// Banners the user waved away, for as long as this tab is open.
    private var dismissedRecovery: Set<String> = []
    /// branch + the commit it was on when the reflog was last read.
    private var lastRecoveryKey: String?
    private var recoveryDeep = false

    // Branches
    @Published var branches: [GitBranch] = []
    @Published var loadingBranches = false
    @Published var branchPickerOpen = false
    @Published var switchTarget: String?

    // Expanded panel
    @Published var detail: DetailTarget?
    @Published var reviewStep = 0
    @Published var generatedMessage: String?
    @Published var conflictCurrent: String?
    @Published var conflictIncoming: String?
    @Published var conflictResolution: String?
    @Published var resolvingConflict = false

    static let compactWidth = WindowMode.compactWidth
    static let expandedWidth = WindowMode.expandedWidth

    // Read through to the shared settings, so the views do not care where
    // these live.
    var cliAvailable: Bool { return settings.cliAvailable }
    /// The chosen provider can answer.
    var aiAvailable: Bool { return settings.aiReady }
    /// ...and can also write files, which conflict resolution needs.
    var aiCanEditFiles: Bool { return settings.aiCanEditFiles }
    var aiProblem: String? { return settings.aiProblem }
    var aiProviderLabel: String { return settings.aiProvider.label }
    var activityMode: ActivityMode {
        get { return settings.activityMode }
        set { settings.activityMode = newValue }
    }
    var stageAllBeforeCommit: Bool { return settings.stageAllBeforeCommit }

    private var repository: GitRepository?
    private let operations: OperationLog
    private var warnedAboutTimeline = false
    private var watcher: FileWatcher?
    /// Workflows: the library, the editor, the run and its history.
    let workflows: WorkflowEngine
    /// Sync & Pull: fetch, put local work aside, rebase, put it back.
    let sync: SyncEngine

    private let agent = CursorAgent()
    /// Held only while an API request is in flight, so it can be cancelled.
    private var httpEngine: HTTPEngine?
    private var refreshing = false
    private var refreshQueued = false
    private var autoFetch: Task<Void, Never>?
    private var lastFetchAt: Date?
    private var branchLoad: Task<Void, Never>?
    private var settingsObserver: AnyCancellable?
    private var workflowObserver: AnyCancellable?
    private var syncObserver: AnyCancellable?
    private var flashTask: Task<Void, Never>?
    private var conflictLoopCancelled = false

    /// What the app is doing right now, in words. Never let a slow git command
    /// look like nothing is happening.
    var busyLabel: String? {
        if let agentBusyLabel { return agentBusyLabel }
        switch phase {
        case .committing:
            return "Creating the commit"
        case .switchingBranch:
            return "Switching to " + (switchTarget ?? "another branch")
        case .pulling:
            return "Pulling from origin"
        case .resolvingConflicts:
            return "Resolving conflicts with AI"
        case .recovering:
            return "Recovering commits"
        case .rebasing:
            return "Replaying the commits"
        case .applyingPlan:
            return "Running the agent's plan"
        case .runningWorkflow:
            return "Running a workflow"
        case .answering:
            return "Working out the answer"
        case .syncing:
            return "Synchronizing with the remote"
        case .stashing:
            return "Moving changes to the stash"
        case .pushing:
            var label = "Pushing to origin/\(repo?.branch ?? "")"
            if pushSeconds > 2 { label += " \u{00b7} \(pushSeconds)s" }
            if pushSeconds > 20 { label += " \u{00b7} it may be waiting for your git credentials" }
            return label
        case .loadingProject:
            return "Opening the project"
        default:
            return fetching ? "Fetching origin" : nil
        }
    }

    var isBusy: Bool {
        // Writing a commit message is an agent run like any other: while one is
        // in flight a second must not start, or the first loses the handle it
        // would be cancelled by.
        if generatingMessage { return true }
        switch phase {
        case .reviewing, .fixing, .verifying, .committing, .pushing, .loadingProject,
             .switchingBranch, .pulling, .stashing, .resolvingConflicts, .recovering,
             .rebasing, .applyingPlan, .runningWorkflow, .answering, .syncing:
            return true
        default:
            return false
        }
    }

    var agentSettings: AgentSettings {
        return settings.agentSettings
    }

    init(root: URL, settings: AppSettings) {
        self.root = root
        self.settings = settings
        self.projectName = root.lastPathComponent
        let repository = GitRepository(root: root)
        self.repository = repository
        self.operations = OperationLog(root: root)
        self.workflows = WorkflowEngine(root: root, repository: repository)
        self.sync = SyncEngine(repository: repository)
        // A settings change (the CLI path, for instance) has to redraw this tab.
        self.settingsObserver = settings.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        // The engine is its own object, so its changes have to reach the views
        // that observe the session.
        self.workflowObserver = workflows.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        workflows.session = self
        self.syncObserver = sync.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        sync.session = self
    }

    // MARK: - Project lifecycle

    /// First load of this tab. The root is already known and validated.
    func start() async {
        phase = .loadingProject
        log(.info, "Opened \(root.lastPathComponent)")
        timeline = await operations.load()
        await refresh(silent: true)
        startWatching(root: root)
        if phase == .loadingProject { phase = .ready }
        await selectAllChanges()
        startAutoFetch()
        await refreshStash()
        await resolveWeb()
        await fetchRemote()
    }

    /// Called when the tab is closed. Everything this session started stops here.
    func teardown() {
        workflows.teardown()
        sync.teardown()
        searchTask?.cancel()
        searchTask = nil
        searching = false
        trackedFiles = []
        trackedFilesAt = nil
        liveRebaseScript?.remove()
        liveRebaseScript = nil
        flashTask?.cancel()
        flashTask = nil
        autoFetch?.cancel()
        autoFetch = nil
        watcher?.stop()
        watcher = nil
        agent.cancel()
        httpEngine?.cancel()
        httpEngine = nil
    }

    private func startWatching(root: URL) {
        watcher?.stop()
        watcher = FileWatcher(root: root) { [weak self] in
            Task { @MainActor in
                await self?.refresh(silent: true, fromWatcher: true)
            }
        }
    }

    // MARK: - Fetch

    /// Keeps the ahead/behind counters honest. Without this the app cannot know
    /// that someone else pushed, and a push would fail out of nowhere.
    /// Fetches only when what the app knows is old enough to be wrong. Called
    /// when the app comes back to the front and when a tab is selected, so both
    /// are free to ask on every single switch.
    func fetchIfStale(after seconds: TimeInterval = 25) async {
        guard repo != nil, !fetching, !isBusy else { return }
        if let last = lastFetchAt, Date().timeIntervalSince(last) < seconds { return }
        await fetchRemote()
    }

    func fetchRemote(silent: Bool = true) async {
        guard let repository, !fetching, !isBusy else { return }
        fetching = true
        lastFetchAt = Date()
        do {
            let behindBefore = repo?.behind ?? 0
            try await repository.fetch()
            await refresh(silent: true)
            if let state = repo, state.behind > behindBefore {
                log(.warning, "origin/\(state.branch) has \(state.behind) commit(s) you do not have")
            }
            // Only a fetch the user asked for. The automatic one every three
            // minutes is not an event worth a line in the timeline.
            if !silent {
                let behind = repo?.behind ?? 0
                await record(.fetch,
                             subject: "origin",
                             detail: behind > 0
                                 ? "\(behind) commit\(behind == 1 ? "" : "s") behind"
                                 : "up to date")
            }
        } catch {
            let problem = GitFailure.describe(error)
            if silent {
                log(.info, "Could not reach origin: \(problem.message)")
            } else {
                errorMessage = problem.full
                log(.failure, "Fetch failed: \(problem.message)")
                await record(.fetch, subject: "origin", detail: problem.message, ok: false)
            }
        }
        fetching = false
    }

    private func startAutoFetch() {
        autoFetch?.cancel()
        autoFetch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 180_000_000_000)
                guard !Task.isCancelled, let self, self.repo != nil else { return }
                await self.fetchRemote()
            }
        }
    }

    // MARK: - Refresh

    func refresh(silent: Bool = false, fromWatcher: Bool = false) async {
        guard let repository else { return }
        if refreshing {
            refreshQueued = true
            return
        }
        refreshing = true
        defer {
            refreshing = false
            if refreshQueued {
                refreshQueued = false
                Task { await refresh(silent: true) }
            }
        }

        do {
            let previousConflicts = repo?.conflicts.count ?? 0
            let state = try await repository.state()
            repo = state
            errorMessage = nil

            if state.hasConflicts && state.conflicts.count != previousConflicts {
                log(.warning, "Conflict detected in \(state.conflicts.count) file(s)")
            }
            if fromWatcher {
                log(.info, "Changes detected: \(state.changes.count) file(s)")
            }

            // Diffs are only computed for the tab in front. A background tab
            // keeps its counters live without spawning git diff on every save.
            let isActive = workspace?.activeID == id
            if let selectedPath, !state.changes.contains(where: { $0.path == selectedPath }) {
                self.selectedPath = nil
                if isActive { await selectAllChanges() }
            } else if let selectedPath, let change = state.changes.first(where: { $0.path == selectedPath }) {
                if isActive { await loadDiff(for: change) }
            } else if selectedPath == nil, isActive {
                await selectAllChanges()
            }

            await refreshStash()
            await refreshRecovery(deep: detail == .recovery)

            // The rebase is over, one way or the other: the todo and its
            // message files are no longer needed by anyone.
            if liveRebaseScript != nil, !state.isRebasing {
                liveRebaseScript?.remove()
                liveRebaseScript = nil
            }

            if let inlinePath {
                if let change = state.changes.first(where: { $0.path == inlinePath }), isActive {
                    await loadInlineDiff(change)
                } else if !state.changes.contains(where: { $0.path == inlinePath }) {
                    self.inlinePath = nil
                    inlineDiff = nil
                }
            }
        } catch {
            if !silent { errorMessage = GitFailure.describe(error).full }
        }
    }

    // MARK: - Diff

    /// Opens the expanded panel on a file: the diff is only loaded on demand.
    func open(change: FileChange) async {
        selectedPath = change.path
        if change.status == .conflict {
            detail = .conflict(change.path)
            conflictResolution = nil
            expandWindow()
            await loadConflictSides(change)
            await loadDiff(for: change)
        } else {
            detail = .file(change.path)
            expandWindow()
            await loadDiff(for: change)
        }
    }

    func openAllChanges() async {
        detail = .allChanges
        expandWindow()
        await selectAllChanges()
    }

    func openProblem(_ problem: AIProblem) async {
        detail = .problem(problem.id)
        expandWindow()
        if let file = problem.file,
           let change = repo?.changes.first(where: { $0.path == file || $0.path.hasSuffix(file) }) {
            selectedPath = change.path
            await loadDiff(for: change)
        } else {
            selectedPath = nil
            fileDiff = nil
            diffTitle = problem.file ?? ""
        }
    }

    func openActivity() {
        detail = .activity
        expandWindow()
    }

    func openStashes() async {
        detail = .stashes
        expandWindow()
        await refreshStash()
    }

    func openRecovery() async {
        detail = .recovery
        expandWindow()
        await refreshRecovery(deep: true)
    }

    func openRebase() async {
        detail = .rebase
        expandWindow()
        await loadRebasePlan()
    }

    func openForge() async {
        detail = .forge
        expandWindow()
        await refreshForge()
    }

    // MARK: - Opening the project elsewhere

    /// The editor the user opened this project with last, when it is still
    /// installed; otherwise the first one that is.
    var preferredEditor: Editor? {
        let saved = Defaults.string("lastEditor", "")
        if !saved.isEmpty, let editor = Editors.editor(withID: saved) { return editor }
        return Editors.installed().first
    }

    /// Opens the whole project folder, not a file in it.
    func openProject(in editor: Editor) {
        let folder = repo?.root ?? root
        Defaults.set("lastEditor", editor.id)
        Editors.open(folder: folder, with: editor) { [weak self] problem in
            guard let self else { return }
            if let problem {
                self.errorMessage = "Could not open this project in \(editor.name): " + problem
            } else {
                self.log(.info, "Opened the project in \(editor.name)")
            }
        }
    }

    func revealProjectInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    func openSync() {
        detail = .sync
        expandWindow()
    }

    /// Opens the panel and starts, which is what the button does.
    func syncAndPull() {
        openSync()
        sync.start()
    }

    /// One line in the timeline for the whole synchronisation.
    func recordSync(_ run: SyncRun, headBefore: String?) async {
        var detail = run.upstream.map { "with \($0)" } ?? "with the remote"
        switch run.phase {
        case .completed:
            if run.behindAtStart > 0 {
                detail += " \u{00b7} \(run.behindAtStart) commit\(run.behindAtStart == 1 ? "" : "s") in"
            } else {
                detail += " \u{00b7} already up to date"
            }
            if run.stashedCount > 0 {
                detail += ", \(run.stashedCount) local change\(run.stashedCount == 1 ? "" : "s") preserved"
            }
        case .conflict:
            detail += " \u{00b7} stopped on a conflict, nothing lost"
        default:
            detail += " \u{00b7} " + (run.problem ?? "failed")
        }
        await record(.pull,
                     subject: "Sync " + run.branch,
                     detail: detail,
                     headBefore: headBefore,
                     ok: run.phase == .completed)
    }

    func openChat() {
        detail = .chat
        expandWindow()
    }

    func openWorkflows() {
        detail = .workflows
        expandWindow()
        Task { await workflows.load() }
    }

    func openWorkflowEditor() {
        detail = .workflowEditor
        expandWindow()
    }

    func openWorkflowRun() {
        detail = .workflowRun
        expandWindow()
    }

    /// One line in the timeline for the whole run, because a workflow is one
    /// operation rather than nine.
    func recordWorkflow(_ run: WorkflowRun, headBefore: String?) async {
        var detail = run.flowLabel
        if let problem = run.problem, !problem.isEmpty {
            detail += " \u{00b7} " + problem
        } else {
            detail += " \u{00b7} \(run.doneCount) of \(run.steps.count) steps in \(run.durationLabel)"
        }
        await record(.workflow,
                     subject: run.workflowName,
                     detail: detail,
                     headBefore: headBefore,
                     ok: run.outcome == .completed)
    }

    /// A workflow moves the branch, the commits, the tree and the stash. None
    /// of that should need the user to press refresh.
    func refreshAfterWorkflow() async {
        await refresh(silent: true)
        await loadBranches()
        await refreshStash()
        await refreshRecovery(deep: detail == .recovery)
        if forgeChecked, forge?.readsDetail == true {
            await refreshForge(force: true)
        }
    }


    /// Opens the panel the tab we came from had open. The panel appears at once
    /// and fills in as this project is read, so switching tabs never collapses
    /// the window.
    func adopt(panel target: DetailTarget) {
        guard target.isProjectIndependent, detail == nil else { return }
        detail = target
        switch target {
        case .stashes:
            Task { await refreshStash() }
        case .recovery:
            Task { await refreshRecovery(deep: true) }
        case .rebase:
            Task { await loadRebasePlan() }
        case .forge:
            Task { await refreshForge() }
        case .allChanges:
            selectedPath = nil
            Task { await selectAllChanges() }
        case .activity, .file, .conflict, .problem, .commit, .plan,
             .workflowEditor, .workflowRun:
            break
        case .workflows:
            Task { await workflows.load() }
        case .chat:
            break
        case .sync:
            break
        }
    }

    func closeDetail() {
        detail = nil
        selectedPath = nil
        commitDetail = nil
        commitDiff = nil
        loadingCommitDiff = false
        applyWindowWidth()
    }

    func problem(with id: UUID) -> AIProblem? {
        return review?.problems.first { $0.id == id }
    }

    // MARK: - Window width

    private func expandWindow() {
        // Opening a panel is the end of a search, whichever way it was asked
        // for: the palette must not sit over what it just opened.
        workspace?.paletteOpen = false
        applyWindowWidth()
    }

    /// The workspace owns the window, so it applies the width.
    func applyWindowWidth() {
        workspace?.applyWindowWidth()
    }

    func selectAllChanges() async {
        guard let repository else { return }
        selectedPath = nil
        diffTitle = "All changes"
        loadingDiff = true
        let raw = await repository.combinedDiff()
        fileDiff = DiffParser.parse(raw, path: "All changes")
        loadingDiff = false
    }

    private func loadDiff(for change: FileChange) async {
        guard let repository else { return }
        diffTitle = change.path
        loadingDiff = true
        let raw = await repository.diff(for: change)
        fileDiff = DiffParser.parse(raw, path: change.path)
        loadingDiff = false
    }

    // MARK: - The next action

    /// What the repository is asking for, in one place, so the button and the
    /// caption can never disagree with each other.
    var primaryAction: PrimaryAction {
        guard let repo else { return .upToDate }
        if repo.hasConflicts { return .resolveConflicts(repo.conflicts.count) }
        if repo.hasChanges {
            let selected = repo.stagedChanges.count
            return .commitAndPush(files: selected > 0 ? selected : repo.changes.count)
        }
        if repo.ahead > 0 || (repo.upstream == nil && !repo.recentCommits.isEmpty) {
            return .push(commits: max(repo.ahead, 1))
        }
        return .upToDate
    }

    /// True when the primary action can actually run right now.
    var primaryActionReady: Bool {
        guard primaryAction.isEnabled, !isBusy else { return false }
        switch primaryAction {
        case .commitAndPush:
            return canCommit
        default:
            return true
        }
    }

    func runPrimaryAction() async {
        switch primaryAction {
        case .commitAndPush:
            await commitAndPush()
        case .push:
            requestPush()
        case .resolveConflicts, .upToDate:
            return
        }
    }

    // MARK: - Transient feedback

    /// A short confirmation that clears itself, for things that worked.
    func flash(_ text: String) {
        statusMessage = text
        flashTask?.cancel()
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard let self, self.statusMessage == text else { return }
            self.statusMessage = nil
        }
    }

    // MARK: - Inline diff

    /// Expands one file in place. Only one at a time, so a long list stays cheap.
    func toggleInline(_ change: FileChange) async {
        if inlinePath == change.path {
            inlinePath = nil
            inlineDiff = nil
            return
        }
        inlinePath = change.path
        await loadInlineDiff(change)
    }

    private func loadInlineDiff(_ change: FileChange) async {
        guard let repository else { return }
        loadingInline = true
        let raw = await repository.diff(for: change, contextLines: 2)
        inlineDiff = DiffParser.parse(raw, path: change.path)
        loadingInline = false
    }

    // MARK: - Pull, stash

    func pull() async {
        guard let repository, let state = repo, !isBusy, !fetching else { return }
        guard !state.hasConflicts, !state.isMerging, !state.isRebasing else {
            errorMessage = "Finish the conflict, merge or rebase in progress before pulling."
            return
        }
        guard state.upstream != nil else {
            errorMessage = "This branch has no upstream to pull from."
            return
        }
        phase = .pulling
        let headBefore = await headSnapshot()
        do {
            let output = try await repository.pull()
            let upToDate = output.lowercased().contains("up to date")
            let behind = state.behind
            log(.success, "Pulled origin/\(state.branch)")
            await record(.pull,
                         subject: "origin/" + state.branch,
                         detail: upToDate
                             ? "already up to date"
                             : (behind > 0 ? "\(behind) commit\(behind == 1 ? "" : "s")" : nil),
                         headBefore: headBefore)
            if upToDate {
                flash("Already up to date")
            } else if behind > 0 {
                flash("Pulled \(behind) commit\(behind == 1 ? "" : "s")")
            } else {
                flash("Pulled from origin")
            }
            review = nil
            reviewError = nil
            phase = .ready
            await refresh(silent: true)
        } catch {
            phase = .ready
            await refresh(silent: true)
            // A rebase that stopped on conflicts is not a failure to report,
            // it is work to do.
            if repo?.hasConflicts == true {
                let count = repo?.conflicts.count ?? 0
                log(.warning, "Pull stopped on \(count) conflict(s)")
                await record(.pull,
                             subject: "origin/" + state.branch,
                             detail: "stopped on \(count) conflict\(count == 1 ? "" : "s")",
                             headBefore: headBefore,
                             ok: false)
                if settings.resolveConflictsWithAI && aiCanEditFiles {
                    await resolveAllConflicts(continuingRebase: true)
                } else {
                    errorMessage = "The pull stopped on \(count) conflict(s). Resolve them and the rebase carries on."
                }
            } else {
                await record(.pull,
                             subject: "origin/" + state.branch,
                             detail: GitFailure.describe(error).message,
                             headBefore: headBefore,
                             ok: false)
                await handleGit(error) { [weak self] in await self?.pull() }
            }
        }
        await refreshStash()
    }

    /// Hands every conflicted file to the agent, checks the markers are really
    /// gone, stages them and carries the rebase forward. Bounded, and it stops
    /// at the first thing it cannot verify.
    func resolveAllConflicts(continuingRebase: Bool) async {
        guard let repository else { return }
        guard phase != .resolvingConflicts else { return }
        if let blocked = aiBlocker(needsFileEdits: true) {
            errorMessage = blocked
            return
        }

        var resolved: Set<String> = []
        var rounds = 0
        conflictLoopCancelled = false

        while rounds < 8 {
            rounds += 1
            if conflictLoopCancelled {
                log(.warning, "Conflict resolution cancelled")
                break
            }
            await refresh(silent: true)
            guard let state = repo else { break }

            let conflicts = state.conflicts.map { $0.path }

            if conflicts.isEmpty {
                guard continuingRebase, state.isRebasing else { break }
                phase = .resolvingConflicts
                do {
                    _ = try await repository.continueRebase()
                    log(.info, "Rebase continued")
                    continue
                } catch {
                    phase = .ready
                    await handleGit(error) { [weak self] in
                        await self?.resolveAllConflicts(continuingRebase: continuingRebase)
                    }
                    return
                }
            }

            phase = .resolvingConflicts
            agentBusyLabel = "Resolving \(conflicts.count) conflict(s) with AI"
            log(.agent, "AI resolving: \(conflicts.joined(separator: ", "))")

            do {
                let result = try await runAgent(prompt: CursorPrompts.resolveConflicts(paths: conflicts, state: state),
                                                workspace: state.root)
                lastAgentReport = result.text
                conflictResolution = result.text
                log(.agent, String(result.text.prefix(400)))
            } catch {
                agentBusyLabel = nil
                phase = .ready
                handleAgent(error: error)
                return
            }
            agentBusyLabel = nil

            // Never take the agent's word for it: look at the files.
            let remaining = repository.filesWithConflictMarkers(conflicts)
            if !remaining.isEmpty {
                phase = .ready
                let names = remaining.joined(separator: ", ")
                log(.failure, "Conflict markers still in \(names)")
                await refresh(silent: true)
                await record(.conflictResolve,
                             subject: "\(remaining.count) file\(remaining.count == 1 ? "" : "s") left unresolved",
                             detail: names,
                             ok: false)
                errorMessage = "The agent could not finish \(names). Resolve what is left by hand, then use Pull again to carry the rebase on."
                return
            }

            do {
                try await repository.stage(paths: conflicts)
                resolved.formUnion(conflicts)
                log(.success, "Resolved and staged \(conflicts.count) file(s)")
            } catch {
                phase = .ready
                await handleGit(error) { [weak self] in
                    await self?.resolveAllConflicts(continuingRebase: continuingRebase)
                }
                return
            }

            guard continuingRebase, repo?.isRebasing == true else { break }

            do {
                _ = try await repository.continueRebase()
                log(.info, "Rebase continued")
            } catch {
                // The next commit being replayed can conflict as well.
                await refresh(silent: true)
                if repo?.hasConflicts == true { continue }
                phase = .ready
                await handleGit(error) { [weak self] in
                    await self?.resolveAllConflicts(continuingRebase: continuingRebase)
                }
                if repo?.isRebasing == true {
                    log(.warning, "Still mid rebase: finish it, or use the menu to abort it")
                }
                return
            }
        }

        phase = .ready
        await refresh(silent: true)
        if resolved.isEmpty {
            flash("Nothing left to resolve")
        } else {
            flash("AI resolved \(resolved.count) file\(resolved.count == 1 ? "" : "s")")
            // A run that was cancelled, ran out of rounds, or left the rebase
            // in progress is not a resolution, whatever it managed on the way.
            let finished = !conflictLoopCancelled && repo?.isRebasing != true && repo?.hasConflicts != true
            await record(.conflictResolve,
                         subject: "\(resolved.count) file\(resolved.count == 1 ? "" : "s")",
                         detail: finished
                             ? resolved.sorted().joined(separator: ", ")
                             : "stopped before the end \u{00b7} " + resolved.sorted().joined(separator: ", "),
                         ok: finished)
        }
        if repo?.isRebasing == true {
            errorMessage = "The rebase is still in progress. Finish it, or use \u{22ef} \u{2192} Abort rebase."
        }
    }

    func abortRebase() async {
        guard let repository, repo?.isRebasing == true, !isBusy else { return }
        phase = .pulling
        let headBefore = await headSnapshot()
        do {
            try await repository.abortRebase()
            phase = .ready
            log(.warning, "Rebase aborted, back to the previous state")
            flash("Rebase aborted")
            await refresh(silent: true)
            await record(.rebaseAbort, subject: repo?.branchLabel ?? "HEAD", headBefore: headBefore)
        } catch {
            phase = .ready
            await handleGit(error) { [weak self] in await self?.abortRebase() }
        }
    }

    /// One `git stash list` keeps both the counter and the manager honest.
    func refreshStash() async {
        _ = await reloadStashes()
    }

    /// Re-reads the list and hands it back, so a caller can resolve a sha to
    /// the ref that entry has right now. A failed read leaves the previous
    /// list alone instead of pretending the stash is empty.
    @discardableResult
    private func reloadStashes() async -> [GitStashEntry]? {
        guard let repository else { return nil }
        guard let list = await repository.stashes() else {
            // Keep whatever the list held: a failed read is not an empty stash.
            stashReadFailed = true
            stashesLoaded = true
            return nil
        }
        stashReadFailed = false
        stashesLoaded = true
        stashes = list
        stashCount = list.count
        // The open entry can have been popped, dropped, or applied elsewhere.
        if let expandedStash, !list.contains(where: { $0.sha == expandedStash }) {
            self.expandedStash = nil
            stashDiff = nil
            loadingStashDiff = false
        }
        // A confirmation whose entry is already gone must not be answered.
        if let pending = pendingStashDrop, !list.contains(where: { $0.sha == pending.sha }) {
            pendingStashDrop = nil
        }
        return list
    }

    /// "stash@{2}" means "the third entry as the list stands now", so the ref
    /// is resolved from the sha immediately before every command that uses it.
    /// Anything else can act on a different entry after the list moved.
    private func currentRef(for entry: GitStashEntry) async -> String? {
        guard let list = await reloadStashes() else { return nil }
        return list.first { $0.sha == entry.sha }?.ref
    }

    /// Reads the diff of one entry, on demand. Only one is open at a time.
    func toggleStash(_ entry: GitStashEntry) async {
        if expandedStash == entry.sha {
            expandedStash = nil
            stashDiff = nil
            loadingStashDiff = false
            return
        }
        expandedStash = entry.sha
        await loadStashDiff(entry)
    }

    private func loadStashDiff(_ entry: GitStashEntry) async {
        guard let repository else { return }
        loadingStashDiff = true
        stashDiff = nil
        // The patch on screen is what Apply will apply, so it is read through
        // the same freshly resolved ref that Apply will use.
        guard let ref = await currentRef(for: entry), expandedStash == entry.sha else {
            loadingStashDiff = false
            return
        }
        let raw = await repository.stashDiff(ref: ref)
        // Another entry was opened while this patch was being read: the flag
        // now belongs to that request, so leave it alone.
        guard expandedStash == entry.sha else { return }
        stashDiff = DiffParser.parse(raw, path: ref)
        loadingStashDiff = false
    }

    /// Applying a stash writes to the working tree, so the repository has to be
    /// settled first. Returns why it cannot run, or nil when it can.
    private var stashApplyBlocker: String? {
        guard let state = repo else { return "The project is still loading." }
        if state.hasConflicts { return "Resolve the conflicts before applying a stash." }
        if state.isMerging || state.isRebasing {
            return "Finish the merge or rebase in progress before applying a stash."
        }
        return nil
    }

    /// Apply keeps the entry, pop removes it. Git itself keeps a popped entry
    /// when the apply ends in conflicts, so no work can be lost here.
    func applyStash(_ entry: GitStashEntry, thenDrop: Bool) async {
        guard let repository, !isBusy else { return }
        if let blocked = stashApplyBlocker {
            errorMessage = blocked
            return
        }
        guard let ref = await currentRef(for: entry) else {
            errorMessage = "\(entry.title) is not in the stash any more."
            return
        }
        phase = .stashing
        do {
            if thenDrop {
                _ = try await repository.stashPop(ref: ref)
            } else {
                _ = try await repository.stashApply(ref: ref)
            }
            log(.success, (thenDrop ? "Popped " : "Applied ") + ref + ": " + entry.title)
            flash((thenDrop ? "Popped " : "Applied ") + entry.title)
            await record(thenDrop ? .stashPop : .stashApply,
                         subject: entry.title,
                         detail: entry.branch.map { "stashed on " + $0 })
            review = nil
            reviewError = nil
            phase = .ready
            await refresh(silent: true)
        } catch {
            phase = .ready
            await refresh(silent: true)
            // An apply that hits conflicts is work to do, not a failure.
            if repo?.hasConflicts == true {
                let count = repo?.conflicts.count ?? 0
                log(.warning, "\(ref) applied with \(count) conflict(s)")
                await record(thenDrop ? .stashPop : .stashApply,
                             subject: entry.title,
                             detail: "applied with \(count) conflict\(count == 1 ? "" : "s")",
                             ok: false)
                errorMessage = thenDrop
                    ? "\(entry.title) applied with \(count) conflict(s), so it stays in the stash. Resolve them, then drop it."
                    : "\(entry.title) applied with \(count) conflict(s). Resolve them before committing."
            } else {
                await handleGit(error) { [weak self] in
                    await self?.applyStash(entry, thenDrop: thenDrop)
                }
            }
        }
        await refreshStash()
    }

    func requestStashDrop(_ entry: GitStashEntry) {
        pendingStashDrop = entry
    }

    /// Only ever runs after the user confirms the dialog.
    func dropStash(_ entry: GitStashEntry) async {
        guard let repository, !isBusy else { return }
        // The entry the user confirmed is found again by its sha: the list can
        // have moved while the dialog was up, and dropping is the one thing
        // here that must never land on the wrong entry.
        guard let ref = await currentRef(for: entry) else {
            errorMessage = "\(entry.title) is not in the stash any more."
            return
        }
        phase = .stashing
        do {
            _ = try await repository.stashDrop(ref: ref)
            // The commit survives until git prunes it, so the sha is the way back.
            log(.warning, "Dropped \(ref): \(entry.title) \u{2014} recover it with git stash apply \(entry.shortSha)")
            flash("Dropped \(entry.title)")
            await record(.stashDrop,
                         subject: entry.title,
                         detail: "still recoverable as " + entry.shortSha)
            if expandedStash == entry.sha {
                expandedStash = nil
                stashDiff = nil
            }
            phase = .ready
        } catch {
            phase = .ready
            await handleGit(error) { [weak self] in await self?.dropStash(entry) }
        }
        await refresh(silent: true)
        // refresh() defers when one is already in flight, and a stale list here
        // carries refs that are off by one.
        await refreshStash()
    }

    /// Branches off the commit the stash was made on, applies it there and
    /// drops the entry. Git refuses when the name is taken or the tree is in
    /// the way, and the stash stays untouched in that case.
    func branchFromStash(_ entry: GitStashEntry, named name: String) async {
        guard let repository, !isBusy else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let blocked = stashApplyBlocker {
            errorMessage = blocked
            return
        }
        guard let ref = await currentRef(for: entry) else {
            errorMessage = "\(entry.title) is not in the stash any more."
            return
        }
        phase = .switchingBranch
        switchTarget = clean
        let headBefore = await headSnapshot()
        do {
            _ = try await repository.stashBranch(named: clean, ref: ref)
            log(.success, "Created \(clean) from \(ref)")
            flash("On \(clean)")
            review = nil
            reviewError = nil
            selectedPath = nil
            expandedStash = nil
            stashDiff = nil
            phase = .ready
            switchTarget = nil
            await refresh(silent: true)
            await record(.stashBranch,
                         subject: clean,
                         detail: "from " + entry.title,
                         headBefore: headBefore)
            await loadBranches()
        } catch {
            phase = .ready
            switchTarget = nil
            await handleGit(error) { [weak self] in await self?.branchFromStash(entry, named: clean) }
        }
        await refreshStash()
    }

    /// Nothing is lost here: the stash keeps the work until it is popped.
    func stashChanges() async {
        guard let repository, let state = repo, state.hasChanges, !isBusy else { return }
        guard !state.hasConflicts, !state.isMerging, !state.isRebasing else {
            errorMessage = "Finish the conflict, merge or rebase in progress before stashing."
            return
        }
        phase = .stashing
        let count = state.changes.count
        let label = "git-agent: \(count) change\(count == 1 ? "" : "s") on \(state.branchLabel)"
        do {
            _ = try await repository.stash(message: label)
            log(.success, "Stashed \(count) change(s)")
            await record(.stash,
                         subject: "\(count) change\(count == 1 ? "" : "s")",
                         detail: "on " + state.branchLabel)
            flash("Stashed \(count) change\(count == 1 ? "" : "s") \u{00b7} pop to restore")
            review = nil
            reviewError = nil
            inlinePath = nil
            inlineDiff = nil
            phase = .ready
            await refresh(silent: true)
        } catch {
            phase = .ready
            await handleGit(error) { [weak self] in await self?.stashChanges() }
        }
        await refreshStash()
    }

    func popStash() async {
        guard let repository, stashCount > 0, !isBusy else { return }
        // Read the list first, so the timeline names the entry git will pop
        // rather than whatever the last refresh happened to see.
        let list = await reloadStashes()
        let newest = list?.first
        phase = .stashing
        do {
            _ = try await repository.stashPop()
            log(.success, "Restored the latest stash")
            await record(.stashPop, subject: newest?.title ?? "the latest stash")
            flash("Stash restored")
            phase = .ready
            await refresh(silent: true)
        } catch {
            phase = .ready
            await handleGit(error) { [weak self] in await self?.popStash() }
        }
        await refreshStash()
    }

    // MARK: - Search

    /// Called when the palette opens. The branch list and the file list are
    /// read once and reused, and the file list is re-read when it has gone
    /// stale rather than on every keystroke.
    func prepareSearch() async {
        if branches.isEmpty { await loadBranches() }
        // Workflows answer by name in the palette, so they have to be there.
        await workflows.load()
        await loadTrackedFiles()
    }

    /// The file list, read at most once a minute. A read that failed is not
    /// remembered as fresh, so the next open tries again instead of reporting
    /// an empty repository for a minute.
    private func loadTrackedFiles() async {
        if let stamp = trackedFilesAt, Date().timeIntervalSince(stamp) <= 60 { return }
        guard let paths = await repository?.trackedFiles(limit: 20_000) else { return }
        trackedFiles = paths.map { ($0, $0.lowercased()) }
        trackedFilesAt = Date()
    }

    func endSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchResults = []
        searching = false
    }

    /// Commands and branches are short lists, so they answer on the keystroke.
    /// Files and commits wait for a pause: scanning twenty thousand paths, and
    /// walking the commit graph, are not things to do per character.
    func updateSearch(_ raw: String) {
        searchTask?.cancel()
        let query = SearchQuery(raw)
        searchResults = SearchHit.deduplicated(instantHits(for: query))
        guard query.needsFileSearch || query.needsCommitSearch else {
            searching = false
            return
        }
        searching = true
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.appendSlowHits(for: query)
        }
    }

    private func instantHits(for query: SearchQuery) -> [SearchHit] {
        switch query.scope {
        case .commands:
            return commandHits(query.text, limit: 12)
        case .branches:
            return branchHits(query.text, limit: 12)
        case .files, .commits, .author:
            return []
        case .all:
            if query.text.isEmpty {
                return workflowHits("", limit: 4) + commandHits("", limit: 6)
            }
            return workflowHits(query.text, limit: 4)
                + commandHits(query.text, limit: 4)
                + branchHits(query.text, limit: 5)
        }
    }

    private func appendSlowHits(for query: SearchQuery) async {
        if query.needsFileSearch {
            await loadTrackedFiles()
            guard !Task.isCancelled else { return }
            let files = fileHits(query.text, limit: query.scope == .files ? 14 : 6)
            searchResults = SearchHit.deduplicated(searchResults + files)
        }

        guard query.needsCommitSearch, let repository else {
            searching = false
            return
        }

        var found: [CommitMatch] = []
        if query.scope == .author {
            found = await repository.searchCommits(text: "", author: query.text, limit: 12)
        } else {
            // A sha prefix is not something --grep can find.
            if let direct = await repository.commit(withPrefix: query.text) { found.append(direct) }
            let byMessage = await repository.searchCommits(text: query.text,
                                                           author: nil,
                                                           limit: query.scope == .commits ? 14 : 8)
            for match in byMessage where !found.contains(where: { $0.commit.sha == match.commit.sha }) {
                found.append(match)
            }
        }
        // The query moved on while git was working.
        guard !Task.isCancelled else { return }
        searching = false
        let words = SearchMatch.words(query.text)
        let hits = found.map { SearchHit.commit($0.commit, matchedLine: $0.matchedLine(for: words)) }
        searchResults = SearchHit.deduplicated(searchResults + hits)
    }

    private func workflowHits(_ text: String, limit: Int) -> [SearchHit] {
        let needle = SearchMatch.words(text)
        var hits: [SearchHit] = []
        for workflow in workflows.workflows {
            let haystack = (workflow.name + " " + workflow.detail + " " + workflow.flowLabel()).lowercased()
            guard SearchMatch.matches(words: needle, in: haystack) else { continue }
            hits.append(.workflow(workflow))
            if hits.count >= limit { break }
        }
        return hits
    }

    private func commandHits(_ text: String, limit: Int) -> [SearchHit] {
        let lower = text.lowercased()

        // "checkout dev" and "create branch x" take what follows as their
        // argument, so they answer with the branches that match it.
        for verb in ["checkout ", "switch ", "co "] where lower.hasPrefix(verb) {
            let name = String(text.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
            return branchHits(name, limit: limit)
        }
        for verb in ["create branch ", "new branch ", "branch "] where lower.hasPrefix(verb) {
            let name = String(text.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { break }
            return [.command(.createBranch(name))]
        }

        var commands: [PaletteCommand] = [
            .syncPull, .askAgent,
            .showWorkflows, .createWorkflow,
            .showChanges, .showActivity, .showStashes, .showRecovery,
            .fetch, .pull, .push, .stash, .popStash,
            .review, .generateMessage, .refresh
        ]
        if repo?.isRebasing == true { commands.insert(.abortRebase, at: 0) }
        if web != nil { commands.append(.openOnWeb) }

        let needle = SearchMatch.words(text)
        var hits: [SearchHit] = []
        for command in commands {
            let haystack = command.keywords.joined(separator: " ").lowercased()
            guard SearchMatch.matches(words: needle, in: haystack) else { continue }
            hits.append(.command(command))
            if hits.count >= limit { break }
        }
        return hits
    }

    private func branchHits(_ text: String, limit: Int) -> [SearchHit] {
        let needle = SearchMatch.words(text)
        var hits: [SearchHit] = []
        for branch in branches where !branch.isCurrent {
            let haystack = (branch.name + " " + branch.localName).lowercased()
            guard SearchMatch.matches(words: needle, in: haystack) else { continue }
            hits.append(.branch(branch))
            if hits.count >= limit { break }
        }
        return hits
    }

    private func fileHits(_ text: String, limit: Int) -> [SearchHit] {
        let needle = SearchMatch.words(text)
        guard !needle.isEmpty else { return [] }
        var hits: [SearchHit] = []

        // What the user is working on comes first.
        let changed = repo?.changes.map { $0.path } ?? []
        for path in changed where SearchMatch.matches(words: needle, in: path.lowercased()) {
            hits.append(.file(path))
            if hits.count >= limit { return hits }
        }
        let seen = Set(changed)
        for file in trackedFiles where !seen.contains(file.path) {
            guard SearchMatch.matches(words: needle, in: file.lower) else { continue }
            hits.append(.file(file.path))
            if hits.count >= limit { break }
        }
        return hits
    }

    /// What pressing return on a row does.
    func activate(_ hit: SearchHit) async {
        workspace?.paletteOpen = false
        endSearch()
        switch hit {
        case .command(let command):
            await run(command)
        case .branch(let branch):
            await switchTo(branch)
        case .commit(let commit, _):
            await openCommit(commit)
        case .file(let path):
            await openPath(path)
        case .workflow(let value):
            await workflows.prepare(value)
        }
    }

    func run(_ command: PaletteCommand) async {
        switch command {
        case .checkout(let name):
            guard let branch = branches.first(where: { $0.name == name || $0.localName == name }) else {
                errorMessage = "There is no branch called \(name)."
                return
            }
            await switchTo(branch)
        case .createBranch(let name):
            await createBranch(named: name)
        case .stash:
            await stashChanges()
        case .popStash:
            await popStash()
        case .fetch:
            await fetchRemote(silent: false)
        case .pull:
            await pull()
        case .push:
            requestPush()
        case .review:
            await reviewChanges()
        case .generateMessage:
            await generateCommitMessage()
        case .refresh:
            await refresh()
        case .abortRebase:
            await abortRebase()
        case .showChanges:
            await openAllChanges()
        case .showActivity:
            openActivity()
        case .showStashes:
            await openStashes()
        case .showRecovery:
            await openRecovery()
        case .showRebase:
            await openRebase()
        case .showForge:
            await openForge()
        case .showWorkflows:
            openWorkflows()
        case .createWorkflow:
            await workflows.load()
            workflows.beginCreate()
        case .askAgent:
            openChat()
        case .syncPull:
            syncAndPull()
        case .openOnWeb:
            openOnWeb(.repo)
        }
    }

    /// Opens one commit in the panel: its message and its whole patch.
    func openCommit(_ commit: GitCommit) async {
        commitDetail = commit
        selectedPath = nil
        detail = .commit(commit.sha)
        expandWindow()
        await loadCommitDiff(commit.sha)
    }

    private func loadCommitDiff(_ sha: String) async {
        guard let repository else { return }
        loadingCommitDiff = true
        commitDiff = nil
        let raw = await repository.show(commit: sha)
        // Something else was opened, or the panel was closed, while git was
        // working. Nothing newer owns the flag, so it is cleared here.
        guard detail == .commit(sha) else {
            loadingCommitDiff = false
            return
        }
        commitDiff = DiffParser.parse(raw, path: sha)
        loadingCommitDiff = false
    }

    /// A path from the palette: its diff when it is one of the changes, and
    /// otherwise the file itself, in whatever the user opens it with.
    func openPath(_ path: String) async {
        if let change = repo?.changes.first(where: { $0.path == path }) {
            await open(change: change)
            return
        }
        guard let root = repo?.root else { return }
        let url = root.appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            statusMessage = "\(path) is not on disk any more."
            return
        }
        // git tracks a submodule as a single entry, and it is a folder.
        if isDirectory.boolValue {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            statusMessage = "\(path) is a folder \u{2014} shown in Finder."
            return
        }
        if !NSWorkspace.shared.open(url) {
            statusMessage = "Could not open \(path)."
        }
    }

    // MARK: - Fixing a failure with the agent

    func clearFailure() {
        failure = nil
    }

    // MARK: - Chat

    /// One turn of the conversation. The answer is text; when the answer needs
    /// git commands they arrive as a plan, and the plan goes through exactly
    /// the same allowlist, confirmation and panel as every other plan.
    func sendChat() async {
        let question = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let repository, let state = repo else { return }
        if let blocked = aiBlocker(needsFileEdits: false) {
            errorMessage = blocked
            return
        }
        guard !isBusy else {
            errorMessage = "Something else is running in this project. Wait for it to finish."
            return
        }

        chatDraft = ""
        chat.append(ChatMessage(role: .you, text: question))
        phase = .answering
        agentBusyLabel = "Working out the answer"
        log(.agent, "Chat: \(question)")

        // The turns before this one, so a follow-up like "and now?" means
        // something. Kept short: the diff and the reflog are the expensive
        // part of the prompt and they are already in it.
        let earlier = chat.dropLast().suffix(6).map { message -> String in
            let who = message.role == .you ? "developer" : "you"
            let line = message.text.replacingOccurrences(of: "\n", with: " ")
            return "  \(who): " + String(line.prefix(400))
        }

        let reflog = state.detached || state.branch.isEmpty
            ? []
            : (await repository.branchReflog(branch: state.branch, limit: 10) ?? [])
        let excluded = state.changes.filter { $0.isSensitive }.map { $0.path }
        let diff = await repository.combinedDiff(excluding: excluded)

        let prompt = CursorPrompts.gitChat(question: question,
                                           history: Array(earlier),
                                           state: state,
                                           diff: diff,
                                           reflog: reflog,
                                           stashes: stashes)
        do {
            let result = try await runAgent(prompt: prompt, workspace: state.root)
            lastAgentReport = result.text
            let parsed = GitPlanParser.parse(result.text)
            let answer = parsed.parsed ? parsed.diagnosis : result.text
            let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)

            if parsed.parsed, !parsed.steps.isEmpty {
                plan = parsed
                planQuestion = question
                pendingStep = nil
                chat.append(ChatMessage(role: .agent,
                                        text: text.isEmpty ? "Here is what I would run." : text,
                                        planSteps: parsed.steps.count))
                log(.success, "Chat proposed \(parsed.steps.count) command(s)")
                if parsed.refusedCount > 0 {
                    log(.warning, "\(parsed.refusedCount) proposed command(s) are not allowed and will be skipped")
                }
            } else {
                chat.append(ChatMessage(role: .agent,
                                        text: text.isEmpty ? "The agent answered with nothing." : text))
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            chat.append(ChatMessage(role: .agent, text: message, failed: true))
            log(.failure, message)
        }
        agentBusyLabel = nil
        phase = .ready
    }

    /// Clears the conversation. The plan it produced is left alone: it may be
    /// half run, and it is the panel's to finish.
    func clearChat() {
        guard !isBusy else { return }
        chat = []
    }

    /// Hands the last failure to the agent and asks for a plan.
    ///
    /// The agent never runs git here: it proposes, the app classifies every
    /// command it proposed, and anything that can lose work waits for a click.
    func fixFailureWithAI() async {
        guard let repository, let state = repo, let failure else { return }
        if let blocked = aiBlocker(needsFileEdits: false) {
            errorMessage = blocked
            return
        }
        guard !isBusy else { return }

        phase = .fixing
        agentBusyLabel = "Working out what to do about \(failure.commandLabel)"
        plan = nil
        planQuestion = nil
        pendingStep = nil
        log(.agent, "AI asked to fix: \(failure.message)")

        // The reflog and the stash are the two things a way out is usually
        // built from, so the agent gets both without having to ask.
        let reflog = state.detached || state.branch.isEmpty
            ? []
            : (await repository.branchReflog(branch: state.branch, limit: 12) ?? [])

        let prompt = CursorPrompts.fixGitFailure(failure: failure,
                                                 state: state,
                                                 reflog: reflog,
                                                 stashes: stashes)
        do {
            let result = try await runAgent(prompt: prompt, workspace: state.root)
            let parsed = GitPlanParser.parse(result.text)
            plan = parsed
            lastAgentReport = result.text
            if parsed.parsed {
                log(.success, "AI proposed \(parsed.steps.count) step(s)")
                if parsed.refusedCount > 0 {
                    log(.warning, "\(parsed.refusedCount) proposed command(s) are not allowed and will be skipped")
                }
                detail = .plan
                expandWindow()
            } else {
                log(.agent, "AI answered without a plan this app can read")
                errorMessage = "The agent answered without a plan Git Agent can read. Its reply is in Activity."
            }
        } catch {
            handleAgent(error: error)
        }
        agentBusyLabel = nil
        phase = .ready
    }

    /// Hands the plan back to the agent with what git said to every command.
    ///
    /// The result of a plan is the one thing the agent cannot see, and it is
    /// exactly what it needs: without this the user reads a failure on screen
    /// that the agent will never know about.
    func retryPlanWithAI() async {
        guard let repository, let state = repo, let previous = plan else { return }
        if let blocked = aiBlocker(needsFileEdits: false) {
            errorMessage = blocked
            return
        }
        guard !isBusy else { return }

        phase = .fixing
        agentBusyLabel = previous.failedCount > 0
            ? "Working out why the plan failed"
            : "Looking at what the plan did"
        pendingStep = nil
        log(.agent, "AI asked to look at the result of its own plan")

        let reflog = state.detached || state.branch.isEmpty
            ? []
            : (await repository.branchReflog(branch: state.branch, limit: 12) ?? [])

        let prompt = CursorPrompts.retryPlan(previous: previous,
                                             question: planQuestion,
                                             failure: failure,
                                             state: state,
                                             reflog: reflog,
                                             stashes: stashes)
        do {
            let result = try await runAgent(prompt: prompt, workspace: state.root)
            let parsed = GitPlanParser.parse(result.text)
            lastAgentReport = result.text
            if parsed.parsed {
                plan = parsed
                log(.success, "AI proposed \(parsed.steps.count) new step(s)")
                if parsed.refusedCount > 0 {
                    log(.warning, "\(parsed.refusedCount) proposed command(s) are not allowed and will be skipped")
                }
                if parsed.steps.isEmpty {
                    statusMessage = "The agent has no command left to offer. Read its diagnosis."
                }
                // The chat is where the conversation lives, when this plan came
                // from one.
                if planQuestion != nil {
                    chat.append(ChatMessage(role: .agent,
                                            text: parsed.diagnosis,
                                            planSteps: parsed.steps.count))
                }
            } else {
                log(.agent, "AI answered without a plan this app can read")
                errorMessage = "The agent answered without a plan Git Agent can read. Its reply is in Activity."
            }
        } catch {
            handleAgent(error: error)
        }
        agentBusyLabel = nil
        phase = .ready
    }

    /// Runs the plan from the top. Steps that already finished are left alone,
    /// so this is also how the plan carries on after a confirmation.
    func runPlan() async {
        guard plan != nil, !runningPlan, !isBusy else { return }
        runningPlan = true
        phase = .applyingPlan
        defer {
            runningPlan = false
            if phase == .applyingPlan { phase = .ready }
        }

        var index = 0
        while let current = plan, index < current.steps.count {
            let step = current.steps[index]
            // Terminal, or already in flight from a confirmation: either way
            // not this loop's to run.
            if step.outcome.isTerminal || step.outcome == .running {
                index += 1
                continue
            }
            if case .refused(let why) = step.risk {
                setOutcome(.skipped(why), at: index)
                index += 1
                continue
            }
            if step.risk.needsConfirmation {
                // Stops here. The dialog names this exact command, and
                // confirming it comes back through confirmPendingStep.
                pendingStep = step
                return
            }
            setOutcome(.running, at: index)
            let outcome = await execute(step)
            setOutcome(outcome, at: index)
            if case .failed = outcome { break }
            index += 1
        }
        await refresh(silent: true)
        if plan?.isFinished == true, plan?.failedCount == 0 {
            flash("The agent's plan finished")
        }
    }

    func confirmPendingStep(_ step: GitCommandStep) async {
        pendingStep = nil
        guard !runningPlan, let current = plan,
              let index = current.steps.firstIndex(where: { $0.id == step.id }) else { return }
        // Held for the whole command: without it the panel's Run button starts
        // a second pass, finds this step still running, and offers to run the
        // very same command again.
        runningPlan = true
        phase = .applyingPlan
        setOutcome(.running, at: index)
        let outcome = await execute(step)
        setOutcome(outcome, at: index)
        runningPlan = false
        if phase == .applyingPlan { phase = .ready }
        await refresh(silent: true)
        if case .failed = outcome { return }
        await runPlan()
    }


    func skipPendingStep(_ step: GitCommandStep) {
        pendingStep = nil
        guard !runningPlan, let current = plan,
              let index = current.steps.firstIndex(where: { $0.id == step.id }) else { return }
        setOutcome(.skipped("you skipped it"), at: index)
        Task { await runPlan() }
    }

    func discardPlan() {
        guard !runningPlan else { return }
        plan = nil
        pendingStep = nil
        if detail == .plan { closeDetail() }
    }

    private func setOutcome(_ outcome: StepOutcome, at index: Int) {
        guard var current = plan, current.steps.indices.contains(index) else { return }
        current.steps[index].outcome = outcome
        plan = current
    }

    /// Runs one step, after classifying it again. The verdict that matters is
    /// the one taken at the moment the command runs, never an earlier one.
    private func execute(_ step: GitCommandStep) async -> StepOutcome {
        guard let repository else { return .failed("The project is no longer open.") }
        let verdict = GitCommandPolicy.classify(step.arguments)
        if case .refused(let why) = verdict { return .skipped(why) }

        log(.tool, step.display)
        do {
            let output = try await repository.runAllowed(step.arguments, risk: verdict)
            await record(.aiCommand, subject: step.display, detail: step.why.isEmpty ? nil : step.why)
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .done(trimmed.isEmpty ? "done" : GitCommandStep.firstLines(trimmed))
        } catch {
            let problem = GitFailure.describe(error)
            log(.failure, "\(step.display) \u{2014} \(problem.message)")
            await record(.aiCommand, subject: step.display, detail: problem.message, ok: false)
            return .failed(problem.full)
        }
    }

    // MARK: - Interactive rebase

    /// How many commits the plan shows at most.
    private static let rebaseLimit = 30

    /// Builds the plan from the commits that can still be rewritten.
    ///
    /// The boundary is deliberate: only commits the upstream does not have.
    /// Rewriting a published commit needs a force push, and this app does not
    /// force push, so it does not offer to rewrite them either.
    func loadRebasePlan() async {
        guard let repository, let state = repo, !loadingRebase else { return }
        loadingRebase = true
        rebaseNote = nil
        rebaseProblem = nil

        // One more than shown, so a longer run can be told from an exact fit.
        var nodes = await repository.rebasableCommits(upstream: state.upstream,
                                                      limit: ProjectSession.rebaseLimit + 1)
        let head = await repository.head()
        loadingRebase = false

        guard !nodes.isEmpty, let head else {
            rebasePlan = nil
            if state.recentCommits.isEmpty {
                rebaseNote = "This branch has no commits yet."
            } else if let upstream = state.upstream {
                rebaseNote = "Every commit on \(state.branchLabel) is already on \(upstream). Rewriting those would need a force push, which Git Agent does not do."
            } else {
                rebaseNote = "There is nothing to reorganize."
            }
            return
        }

        // git returns the newest N and then reverses them, so trimming means
        // dropping the oldest of what came back.
        let truncated = nodes.count > ProjectSession.rebaseLimit
        if truncated { nodes.removeFirst(nodes.count - ProjectSession.rebaseLimit) }

        // The base is the parent of the oldest commit **in the list**, never
        // the upstream tip. Two reasons, both of them data loss otherwise:
        // a commit outside the list would be replayed away, and rebasing onto
        // the upstream tip would quietly pull the remote's commits in as well.
        let base: RebaseBase
        if let parent = nodes.first?.parents.first {
            base = .rev(parent)
        } else {
            base = .root
        }

        let steps = nodes.map { RebaseStep(commit: $0.commit, isMerge: $0.isMerge) }
        rebasePlan = RebasePlan(base: base,
                                branch: state.branchLabel,
                                head: head,
                                truncated: truncated,
                                steps: steps,
                                originalIDs: steps.map { $0.id })
    }

    func setRebaseAction(_ action: RebaseAction, at index: Int) {
        guard !isBusy, var plan = rebasePlan, plan.steps.indices.contains(index) else { return }
        plan.steps[index].action = action
        // Rewording starts from what the message already says.
        if action == .reword, plan.steps[index].message.isEmpty {
            plan.steps[index].message = plan.steps[index].commit.subject
        }
        rebasePlan = plan
        rebaseProblem = nil
    }

    func setRebaseMessage(_ message: String, at index: Int) {
        guard !isBusy, var plan = rebasePlan, plan.steps.indices.contains(index) else { return }
        plan.steps[index].message = message
        rebasePlan = plan
    }

    func moveRebaseSteps(from source: IndexSet, to destination: Int) {
        guard !isBusy, var plan = rebasePlan else { return }
        plan.steps.move(fromOffsets: source, toOffset: destination)
        rebasePlan = plan
        rebaseProblem = nil
    }

    /// The keyboard and mouse alternative to dragging.
    func nudgeRebaseStep(at index: Int, by offset: Int) {
        guard !isBusy, var plan = rebasePlan else { return }
        let target = index + offset
        guard plan.steps.indices.contains(index), plan.steps.indices.contains(target) else { return }
        plan.steps.swapAt(index, target)
        rebasePlan = plan
        rebaseProblem = nil
    }

    func resetRebasePlan() async {
        guard !isBusy else { return }
        rebasePlan = nil
        await loadRebasePlan()
    }

    /// Checks everything that can be checked before the dialog, so the
    /// confirmation is the last thing standing between the plan and the repo.
    func requestRebase() {
        guard let plan = rebasePlan, let state = repo else { return }
        if let problem = plan.problem {
            rebaseProblem = problem
            return
        }
        guard plan.changesAnything else {
            rebaseProblem = "The plan is the same as what is already there."
            return
        }
        if let blocked = rebaseBlocker(state) {
            rebaseProblem = blocked
            return
        }
        pendingRebase = plan
    }

    /// Why a rebase cannot start right now, or nil when it can. Checked when
    /// the dialog is offered and again before the command runs.
    private func rebaseBlocker(_ state: RepoState) -> String? {
        if state.hasConflicts || state.isMerging || state.isRebasing {
            return "Finish the conflict, merge or rebase in progress first."
        }
        if state.hasChanges {
            let count = state.changes.count
            return "Commit or stash your \(count) change\(count == 1 ? "" : "s") first \u{2014} replaying commits needs a clean working tree."
        }
        if state.detached {
            return "HEAD is detached. Check out a branch first."
        }
        return nil
    }

    /// Runs the plan. Everything the plan replaces stays in the reflog, so
    /// Recovery can put the branch back exactly where it was.
    func runRebase(_ plan: RebasePlan) async {
        guard let repository, let state = repo, !isBusy else { return }
        if let problem = plan.problem {
            rebaseProblem = problem
            return
        }
        if let blocked = rebaseBlocker(state) {
            rebaseProblem = blocked
            return
        }
        // The plan lists every commit that will be replayed. A commit made
        // since it was read is not in the list, and replaying the list would
        // delete it. Read HEAD again rather than trust the last refresh.
        let currentHead = await repository.head()
        guard currentHead == plan.head else {
            rebaseProblem = "\(plan.branch) has moved since this plan was read. It has been read again \u{2014} check it and start over."
            await loadRebasePlan()
            return
        }

        let script: RebaseScript
        do {
            script = try RebaseScript.write(plan)
        } catch {
            rebaseProblem = "Could not write the plan: \(error.localizedDescription)"
            return
        }

        phase = .rebasing
        let headBefore = await headSnapshot()
        log(.info, "Rebase: \(plan.summary) \u{00b7} \(plan.actionSummary)")

        do {
            _ = try await repository.runInteractiveRebase(base: plan.base, todo: script.todo)
            script.remove()
            log(.success, "Replayed \(plan.steps.count) commit(s) on \(plan.branch)")
            flash("Rebase finished \u{00b7} \(plan.summary)")
            review = nil
            reviewError = nil
            inlinePath = nil
            inlineDiff = nil
            rebaseProblem = nil
            phase = .ready
            await record(.rebase,
                         subject: plan.branch + " \u{00b7} " + plan.summary,
                         detail: plan.actionSummary,
                         headBefore: headBefore)
            await refresh(silent: true)
            await loadRebasePlan()
        } catch {
            phase = .ready
            await refresh(silent: true)
            let problem = GitFailure.describe(error)
            if repo?.hasConflicts == true || repo?.isRebasing == true {
                // The rest of the todo is still to run, and it names the
                // message files by path. Deleting them now would break the
                // `git rebase --continue` that follows, so the script lives
                // until the rebase is no longer in progress.
                liveRebaseScript = script
                let count = repo?.conflicts.count ?? 0
                log(.warning, "Rebase stopped on \(count) conflict(s)")
                await record(.rebase,
                             subject: plan.branch + " \u{00b7} " + plan.summary,
                             detail: count > 0 ? "stopped on \(count) conflict(s)" : "stopped part way",
                             headBefore: headBefore,
                             ok: false)
                errorMessage = count > 0
                    ? "The rebase stopped on \(count) conflict(s). Resolve them, or use \u{22ef} \u{2192} Abort rebase to go back to where you were."
                    : "The rebase stopped part way. Use \u{22ef} \u{2192} Abort rebase to go back to where you were."
            } else {
                script.remove()
                await record(.rebase,
                             subject: plan.branch + " \u{00b7} " + plan.summary,
                             detail: problem.message,
                             headBefore: headBefore,
                             ok: false)
                await handleGit(error) { [weak self] in await self?.runRebase(plan) }
            }
        }
    }

    // MARK: - GitHub / GitLab

    /// Reads which host this repository is on, whether its CLI is installed and
    /// logged in, and then the request for this branch.
    ///
    /// Never called when a project opens: it goes to the network, and nine tabs
    /// should not mean nine requests before the user has asked for anything.
    func refreshForge(force: Bool = false) async {
        guard let repository, let state = repo, !loadingForge else { return }
        let key = state.branchLabel
        if !force, forgeChecked, forgeLoadedFor == key { return }

        loadingForge = true
        forgeError = nil

        if forge == nil || force {
            let remote = await repository.remoteURL()
            web = ForgeWeb.from(remote: remote)
            forge = await ForgeClient.detect(root: root, remote: remote)
        }
        forgeChecked = true
        forgeLoadedFor = key

        guard let info = forge, info.readsDetail else {
            forgePR = nil
            forgePRs = []
            forgeIssues = []
            loadingForge = false
            return
        }

        let client = ForgeClient(root: root, info: info)

        let request = await client.pullRequest(forBranch: state.branch)
        let list = await client.pullRequests(limit: 8)
        let assigned = await client.issues(limit: 6)

        // A read that failed keeps whatever was there and says what happened.
        // "No pull request" has to mean there is none.
        if let problem = request.problem ?? list.problem ?? assigned.problem {
            forgeError = problem
            log(.failure, "\(info.kind.cli): \(problem)")
        }
        if request.problem == nil { forgePR = request.request }
        if list.problem == nil { forgePRs = list.requests }
        if assigned.problem == nil { forgeIssues = assigned.issues }
        loadingForge = false
    }

    /// Called after a push: that is exactly when the question "did this update
    /// the pull request" comes up.
    private func refreshForgeInBackground() {
        guard forgeChecked, forge?.readsDetail == true else { return }
        Task { @MainActor [weak self] in await self?.refreshForge(force: true) }
    }

    /// Reads origin once so the "open on the web" entries know what to offer.
    func resolveWeb() async {
        guard let repository else { return }
        web = ForgeWeb.from(remote: await repository.remoteURL())
    }

    /// Opens one of this repository's pages on its host.
    func openOnWeb(_ page: ForgeWeb.Page) {
        guard let web, let url = web.url(for: page) else {
            statusMessage = "This repository's remote is not a GitHub or GitLab address."
            return
        }
        if NSWorkspace.shared.open(url) {
            log(.info, "Opened \(web.label(for: page).lowercased())")
        } else {
            statusMessage = "Could not open \(url.absoluteString)."
        }
    }

    /// The branch page, or the repository when HEAD is detached.
    func openBranchOnWeb() {
        guard let state = repo, !state.detached, !state.branch.isEmpty else {
            openOnWeb(.repo)
            return
        }
        openOnWeb(.branch(state.branch))
    }

    func openForgeURL(_ url: String) {
        guard let target = URL(string: url) else { return }
        if !NSWorkspace.shared.open(target) {
            statusMessage = "Could not open \(url)."
        }
    }

    /// The web page is where a request gets published, not the app: the title,
    /// the base branch and the reviewers are decisions the form already asks.
    func createForgeRequest() async {
        guard let info = forge, info.canOpen, !isBusy else { return }
        loadingForge = true
        let problem = await ForgeClient(root: root, info: info).openCreateForm()
        loadingForge = false
        if let problem, !problem.isEmpty {
            forgeError = problem
            log(.failure, "\(info.kind.cli): \(problem)")
        } else {
            log(.info, "Opened the \(info.kind.requestName) form in the browser")
            flash("Opened in your browser")
        }
    }

    func openForgeRequest() async {
        guard let info = forge, info.canOpen else { return }
        if let pr = forgePR, !pr.url.isEmpty {
            openForgeURL(pr.url)
            return
        }
        loadingForge = true
        let problem = await ForgeClient(root: root, info: info).openRequestInBrowser()
        loadingForge = false
        if let problem, !problem.isEmpty {
            forgeError = problem
        }
    }

    // MARK: - Recovery

    /// Reads where the current branch has been, from git's own reflog.
    ///
    /// The reflog itself is a file read, so it costs nothing. Counting the
    /// commits one move left behind costs a `git log` each, so a plain refresh
    /// only counts the newest move — which is what the banner needs — and the
    /// panel asks for the rest. Nothing is read at all while the branch has not
    /// moved since the last look.
    func refreshRecovery(deep: Bool = false) async {
        guard let repository, let state = repo, !state.detached, !state.branch.isEmpty else {
            recoveryPoints = []
            recoveryBanner = nil
            recoveryReadFailed = false
            recoveryLoaded = true
            // Not keyed to anything any more: the next branch has to be read.
            lastRecoveryKey = nil
            recoveryDeep = false
            return
        }
        // The branch is part of the key: two branches can sit on the same
        // commit, and their histories are not the same.
        let key = state.branch + "@" + (state.recentCommits.first?.sha ?? "")
        if recoveryLoaded, key == lastRecoveryKey, !deep || recoveryDeep {
            // Nothing moved and nothing more is being asked for. The banner
            // still has to age out on its own.
            updateRecoveryBanner()
            return
        }

        loadingRecovery = true
        guard let entries = await repository.branchReflog(branch: state.branch, limit: 12) else {
            // A reflog that could not be read is not a branch that never moved.
            recoveryReadFailed = true
            recoveryPoints = []
            recoveryBanner = nil
            recoveryLoaded = true
            loadingRecovery = false
            lastRecoveryKey = nil
            recoveryDeep = false
            return
        }
        recoveryReadFailed = false

        var points: [RecoveryPoint] = []
        for entry in entries {
            // The line that created the branch has no previous position.
            guard !entry.isCreation, entry.old != entry.sha else { continue }
            var lost: [GitCommit] = []
            var rewritten = 0
            var more = false
            var counted = true
            if !entry.couldLoseCommits {
                // A commit or a branch creation can only add: counted, at zero.
                counted = true
            } else if deep || points.isEmpty {
                if let found = await repository.commitsLeftBehind(kept: entry.sha,
                                                                  dropped: entry.old,
                                                                  limit: 11) {
                    // A rebase replays commits under new shas. Those are not
                    // lost, and reporting them as lost is what makes an
                    // ordinary pull look like an accident.
                    var replayed: Set<String> = []
                    if !found.isEmpty {
                        replayed = await repository.rewrittenShas(kept: entry.sha,
                                                                  dropped: entry.old) ?? []
                    }
                    let gone = found.filter { !replayed.contains($0.sha) }
                    rewritten = found.count - gone.count
                    // One more than shown, so "10+" can be told from "10".
                    more = gone.count > 10
                    lost = Array(gone.prefix(10))
                } else {
                    counted = false
                }
            } else {
                counted = false
            }
            points.append(RecoveryPoint(branch: state.branch,
                                        entry: entry,
                                        from: entry.old,
                                        to: entry.sha,
                                        lost: lost,
                                        rewritten: rewritten,
                                        moreLost: more,
                                        counted: counted))
        }

        recoveryPoints = points
        lastRecoveryKey = key
        recoveryDeep = deep
        recoveryLoaded = true
        loadingRecovery = false
        updateRecoveryBanner()
    }

    /// The banner is for a loss the app did not cause. Something the user asked
    /// this app to do is not a surprise; a reset typed into a terminal is, and
    /// that is the case this exists for.
    private func updateRecoveryBanner() {
        guard let newest = recoveryPoints.first, newest.isLoss,
              !dismissedRecovery.contains(newest.id) else {
            recoveryBanner = nil
            return
        }
        // Older than half an hour and it is history, not an accident.
        guard Date().timeIntervalSince(newest.entry.date) < 1800 else {
            recoveryBanner = nil
            return
        }
        let ours = timeline.suffix(12).contains { $0.ok && $0.headAfter == newest.to }
        recoveryBanner = ours ? nil : newest
    }

    func dismissRecoveryBanner() {
        guard let banner = recoveryBanner else { return }
        dismissedRecovery.insert(banner.id)
        recoveryBanner = nil
    }

    /// Puts a branch at the commit the current branch left behind. Nothing else
    /// moves, so this recovery cannot cost anything.
    func restoreAsBranch(_ point: RecoveryPoint) async {
        guard let repository, !isBusy else { return }
        let base = "recovered/" + point.shortFrom
        var name = base
        var attempt = 1

        // The name is taken when the commit was already restored, or when a
        // different commit abbreviates the same way. Check which.
        while let existing = await repository.resolve(name) {
            if existing == point.from {
                log(.info, "\(name) already points at \(point.shortFrom)")
                flash("Already restored as \(name)")
                return
            }
            attempt += 1
            guard attempt <= 9 else {
                errorMessage = "Could not find a free name for the recovery branch. \(base) and \(base)-2 through \(base)-9 are taken."
                return
            }
            name = base + "-" + String(attempt)
        }

        phase = .recovering
        do {
            _ = try await repository.createBranch(named: name, at: point.from)
            log(.success, "Created \(name) at \(point.shortFrom)")
            flash("Restored as \(name)")
            phase = .ready
            await record(.recoverBranch, subject: name, detail: "at " + point.shortFrom)
            await refresh(silent: true)
            await loadBranches()
        } catch {
            phase = .ready
            await handleGit(error) { [weak self] in await self?.restoreAsBranch(point) }
        }
    }

    /// Checks the move is possible and asks the user to confirm it.
    func requestMoveBack(_ point: RecoveryPoint) {
        guard let blocked = moveBackBlocker(point) else {
            pendingRecoveryReset = point
            return
        }
        errorMessage = blocked
    }

    /// Why the branch cannot be moved back right now, or nil when it can.
    ///
    /// Read by the panel as well, so the button explains itself instead of
    /// failing with a git error after the click. Checked again immediately
    /// before the command, so nothing that changed in between slips through.
    func moveBackBlocker(_ point: RecoveryPoint) -> String? {
        guard let state = repo else { return "The project is still loading." }
        guard !state.detached, state.branch == point.branch else {
            return "Check out \(point.branch) first \u{2014} this moves that branch."
        }
        if state.hasConflicts || state.isMerging || state.isRebasing {
            return "Finish the conflict, merge or rebase in progress before moving the branch."
        }
        // git reset --keep refuses rather than overwrite an uncommitted change,
        // which is the point of it. Saying so here beats letting git say it.
        if state.hasChanges {
            let count = state.changes.count
            return "\(count) uncommitted change\(count == 1 ? "" : "s") would be overwritten by this move. Stash them first, move the branch, then pop the stash."
        }
        return nil
    }

    /// True when a dirty working tree is the only thing in the way, so the
    /// panel can offer the one step that clears it.
    func onlyNeedsStash(_ point: RecoveryPoint) -> Bool {
        guard let state = repo else { return false }
        guard state.hasChanges, !state.hasConflicts, !state.isMerging, !state.isRebasing else { return false }
        return !state.detached && state.branch == point.branch
    }

    /// Moves the current branch back to where it was. `git reset --keep`, never
    /// `--hard`: git refuses when an uncommitted change would be overwritten,
    /// and where the branch is now stays in the reflog, so this is itself
    /// recoverable. Only ever runs after the user confirms the dialog.
    func moveBranchBack(_ point: RecoveryPoint) async {
        guard let repository, !isBusy else { return }
        if let blocked = moveBackBlocker(point) {
            errorMessage = blocked
            return
        }
        // Where the branch is now, read again rather than taken from the last
        // refresh: only the last move can be undone in one step, and the
        // dialog may have been sitting open while something else moved it.
        let current = await repository.head()
        guard current == point.to else {
            errorMessage = "\(point.branch) has moved since. Nothing was changed \u{2014} reopen Recovery to see where it is now."
            await refreshRecovery(deep: detail == .recovery)
            return
        }

        phase = .recovering
        let headBefore = await headSnapshot()
        do {
            _ = try await repository.resetKeep(to: point.from)
            log(.success, "Moved \(point.branch) back to \(point.shortFrom)")
            flash("\(point.branch) is back at \(point.shortFrom)")
            review = nil
            reviewError = nil
            inlinePath = nil
            inlineDiff = nil
            phase = .ready
            // Recorded before the refresh: the banner decides whether a loss
            // was the app's own doing by looking for this record, and the
            // refresh is what recomputes it.
            await record(.recoverReset,
                         subject: point.branch + " \u{2192} " + point.shortFrom,
                         detail: point.isLoss ? point.lostLabel + " back on the branch" : nil,
                         headBefore: headBefore)
            await refresh(silent: true)
            await refreshRecovery(deep: detail == .recovery)
        } catch {
            phase = .ready
            await handleGit(error) { [weak self] in await self?.moveBranchBack(point) }
        }
    }

    // MARK: - Branches

    /// Waits for the load already in flight rather than returning while the
    /// list is still empty: a caller that reads `branches` right after this
    /// would otherwise decide the repository has no branches at all.
    func loadBranches() async {
        if let branchLoad {
            await branchLoad.value
            return
        }
        guard let repository else { return }
        loadingBranches = true
        let load = Task { @MainActor in
            self.branches = await repository.branches()
        }
        branchLoad = load
        await load.value
        branchLoad = nil
        loadingBranches = false
    }

    /// Branches off the current HEAD. The name is validated by git itself.
    func createBranch(named name: String) async {
        guard let repository, !isBusy else { return }
        branchPickerOpen = false
        phase = .switchingBranch
        switchTarget = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let headBefore = await headSnapshot()
        let from = repo?.branchLabel ?? "HEAD"
        do {
            _ = try await repository.createBranch(named: name)
            log(.success, "Created and switched to \(switchTarget ?? name)")
            flash("On \(switchTarget ?? name)")
            review = nil
            reviewError = nil
            await refresh(silent: true)
            await record(.branchCreate,
                         subject: switchTarget ?? name,
                         detail: "from " + from,
                         headBefore: headBefore)
            phase = .ready
            switchTarget = nil
            await loadBranches()
        } catch {
            phase = .ready
            switchTarget = nil
            await handleGit(error) { [weak self] in await self?.createBranch(named: name) }
        }
    }

    /// Switching never discards anything: git refuses when a file would be
    /// overwritten, and the app does not offer to force it.
    /// `offerStash` is false on the retry after stashing: git can accept the
    /// stash and still refuse the switch (a nested repository is skipped with
    /// "Ignoring path"), and offering the same fix again would loop.
    func switchTo(_ branch: GitBranch, offerStash: Bool = true) async {
        guard let repository, let state = repo, !branch.isCurrent else { return }
        guard !state.hasConflicts else {
            errorMessage = "Resolve the conflicts before switching branches."
            return
        }
        guard !state.isMerging && !state.isRebasing else {
            errorMessage = "Finish the merge or rebase in progress before switching branches."
            return
        }
        guard !isBusy else { return }

        branchPickerOpen = false
        phase = .switchingBranch
        switchTarget = branch.isRemote ? branch.localName : branch.name
        let headBefore = await headSnapshot()
        let from = state.branchLabel

        do {
            _ = try await repository.switchBranch(to: branch)
            log(.success, "Switched to \(switchTarget ?? branch.name)")
            // The review, the diff and any push failure belonged to the
            // previous HEAD.
            review = nil
            reviewError = nil
            touchedFiles = []
            lastAgentReport = nil
            selectedPath = nil
            pushProblem = nil
            statusMessage = nil
            detail = nil
            // Which files exist is a property of the branch.
            trackedFiles = []
            trackedFilesAt = nil
            // So are the plan and the pull request.
            rebasePlan = nil
            rebaseNote = nil
            rebaseProblem = nil
            forgePR = nil
            forgeLoadedFor = nil
            applyWindowWidth()
            await refresh(silent: true)
            await record(.checkout,
                         subject: switchTarget ?? branch.name,
                         detail: "from " + from,
                         headBefore: headBefore)
            phase = .ready
            switchTarget = nil
            await loadBranches()
            await fetchRemote()
        } catch {
            phase = .ready
            switchTarget = nil
            // "The following untracked working tree files would be overwritten
            // by checkout" is not a broken repository: those files are simply
            // not in git, and putting them in the stash clears the way without
            // losing a byte of them.
            let problem = GitFailure.describe(error)
            let blocked = GitFailure.blockedPaths(in: problem.raw)
            if offerStash, GitFailure.isUntrackedBlock(problem.raw), !blocked.isEmpty {
                log(.failure, "Switching to \(branch.localName) is blocked by \(blocked.count) untracked file(s)")
                failure = AIFailure(command: problem.command,
                                    message: problem.message,
                                    raw: problem.raw.isEmpty ? problem.full : problem.raw)
                blockedSwitch = BlockedSwitch(branch: branch, paths: blocked)
                return
            }
            await handleGit(error) { [weak self] in await self?.switchTo(branch) }
        }
    }

    /// Puts the files that are in the way into the stash, then switches.
    ///
    /// They stay there: popping them straight back would put them on the new
    /// branch, which may well be where they came from being in the way. The
    /// stash panel is one click away and nothing was deleted.
    func stashAndSwitch(_ blocked: BlockedSwitch) async {
        blockedSwitch = nil
        guard let repository, !isBusy else { return }
        let target = blocked.branch.localName
        phase = .stashing
        let label = "git-agent: in the way of \(target)"
        do {
            let output = try await repository.stash(message: label)
            let count = blocked.paths.count
            // "No local changes to save" is an exit of zero: git saved nothing,
            // and saying it stashed the files would be a lie the next error
            // contradicts. "Ignoring path" is git skipping a nested repository.
            let savedNothing = output.contains("No local changes to save")
            if savedNothing {
                log(.warning, "Nothing could be stashed \u{2014} the files are not git's to move")
            } else {
                log(.success, "Stashed \(count) file\(count == 1 ? "" : "s") that blocked the switch")
                if output.contains("Ignoring path") {
                    log(.warning, "Some paths were skipped: " + GitCommandStep.firstLines(output, 2))
                }
                await record(.stash,
                             subject: "\(count) file\(count == 1 ? "" : "s")",
                             detail: "in the way of " + target)
            }
            phase = .ready
            await refresh(silent: true)
            await refreshStash()
            // Not offering again: if it is still blocked, git's own message is
            // what the user needs now.
            await switchTo(blocked.branch, offerStash: false)
            if repo?.branchLabel == target, !savedNothing {
                flash("Switched \u{00b7} what was in the way is in the stash")
            }
        } catch {
            phase = .ready
            await handleGit(error) { [weak self] in await self?.stashAndSwitch(blocked) }
        }
    }

    // MARK: - Staging

    func toggleStage(_ change: FileChange) async {
        guard let repository else { return }
        do {
            if change.staged && !change.unstaged {
                try await repository.unstage(paths: [change.path])
            } else {
                try await repository.stage(paths: [change.path])
            }
            await refresh(silent: true)
        } catch {
            let path = change.path
            await handleGit(error) { [weak self] in
                guard let self,
                      let current = self.repo?.changes.first(where: { $0.path == path }) else { return }
                await self.toggleStage(current)
            }
        }
    }

    /// Clears the selection by unstaging everything. The working tree is untouched.
    func deselectAll() async {
        guard let repository, let state = repo else { return }
        let paths = state.changes.filter { $0.staged && $0.status != .conflict }.map { $0.path }
        guard !paths.isEmpty else { return }
        do {
            try await repository.unstage(paths: paths)
            log(.info, "Cleared the selection")
            await refresh(silent: true)
        } catch {
            await handleGit(error) { [weak self] in await self?.deselectAll() }
        }
    }

    func stageAll() async {
        guard let repository else { return }
        do {
            try await repository.stageAll()
            log(.info, "Staged all changes")
            await refresh(silent: true)
        } catch {
            await handleGit(error) { [weak self] in await self?.stageAll() }
        }
    }

    // MARK: - AI review

    func reviewChanges() async {
        guard let repository, let state = repo, !isBusy, !generatingMessage else { return }
        guard state.hasChanges else {
            statusMessage = "Nothing to review."
            return
        }
        if let blocked = aiBlocker(needsFileEdits: false) {
            errorMessage = blocked
            return
        }

        phase = .reviewing
        agentBusyLabel = "Reviewing changes"
        review = nil
        reviewError = nil
        reviewStep = 0
        let stepper = Task { @MainActor [weak self] in
            for step in 1...2 {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, self.phase == .reviewing else { return }
                self.reviewStep = step
            }
        }
        log(.agent, "AI review started on \(state.changes.count) file(s)")

        let excluded = state.changes.filter { $0.isSensitive }.map { $0.path }
        if !excluded.isEmpty {
            log(.warning, "Withheld diff of sensitive file(s): \(excluded.joined(separator: ", "))")
        }
        let diff = await repository.combinedDiff(excluding: excluded)
        let prompt = CursorPrompts.review(state: state, diff: diff)

        do {
            let result = try await runAgent(prompt: prompt, workspace: state.root)
            let parsed = ReviewParser.parse(result.text)
            review = parsed
            if parsed.parsed {
                log(.success, "AI reviewed \(state.changes.count) file(s): \(parsed.issues.count) problem(s), risk \(parsed.risk.label.lowercased())")
                if let first = parsed.issues.first {
                    log(.warning, "Potential issue: \(first.title)")
                }
            } else {
                log(.agent, "AI answered without structured JSON, showing raw output")
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            reviewError = message
            log(.failure, message)
        }
        stepper.cancel()
        reviewStep = 0
        agentBusyLabel = nil
        phase = .ready
        await refresh(silent: true)
    }

    // MARK: - AI fix

    func fix(problem: AIProblem) async {
        guard let repository, let state = repo else { return }
        if let blocked = aiBlocker(needsFileEdits: true) {
            errorMessage = blocked
            return
        }
        phase = .fixing
        agentBusyLabel = "Fixing: \(problem.title)"
        log(.agent, "AI fixing: \(problem.title)")

        let excluded = state.changes.filter { $0.isSensitive }.map { $0.path }
        let diff = await repository.combinedDiff(excluding: excluded)
        let prompt = CursorPrompts.fix(problem: problem, state: state, diff: diff)

        do {
            let result = try await runAgent(prompt: prompt, workspace: state.root)
            lastAgentReport = result.text
            touchedFiles = result.touchedFiles
            if result.touchedFiles.isEmpty {
                log(.agent, "AI finished without reporting file changes")
            } else {
                log(.success, "AI changed \(result.touchedFiles.count) file(s): \(result.touchedFiles.joined(separator: ", "))")
                await record(.aiFix,
                             subject: problem.title,
                             detail: result.touchedFiles.joined(separator: ", "))
            }
        } catch {
            handleAgent(error: error)
        }
        agentBusyLabel = nil
        phase = .ready
        await refresh(silent: true)
    }

    // MARK: - Commit message

    func generateCommitMessage() async {
        guard let repository, let state = repo else { return }
        if let blocked = aiBlocker(needsFileEdits: false) {
            errorMessage = blocked
            return
        }
        guard state.hasChanges, !isBusy, !generatingMessage else { return }

        generatingMessage = true
        agentBusyLabel = "Writing commit message"
        let excluded = state.changes.filter { $0.isSensitive }.map { $0.path }
        let diff = await repository.combinedDiff(excluding: excluded)
        let prompt = CursorPrompts.commitMessage(state: state, diff: diff)

        do {
            let result = try await runAgent(prompt: prompt, workspace: state.root, quiet: true)
            let message = CommitMessageCleaner.clean(result.text)
            if message.isEmpty {
                log(.failure, "The agent returned an empty commit message")
            } else {
                commitMessage = message
                generatedMessage = message
                log(.agent, "Commit message generated")
            }
        } catch {
            handleAgent(error: error)
        }
        agentBusyLabel = nil
        generatingMessage = false
    }

    // MARK: - Commit and push

    var canCommit: Bool {
        guard let repo, !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if repo.hasConflicts { return false }
        if !repo.stagedChanges.isEmpty { return true }
        return stageAllBeforeCommit && repo.hasChanges
    }

    func commit() async -> Bool {
        guard let repository, let state = repo else { return false }
        guard !state.hasConflicts else {
            errorMessage = "Resolve the conflicts before committing."
            return false
        }
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return false }

        phase = .committing
        let files = state.stagedChanges.isEmpty ? state.changes.count : state.stagedChanges.count
        let headBefore = await headSnapshot()
        do {
            if state.stagedChanges.isEmpty && stageAllBeforeCommit && state.hasChanges {
                try await repository.stageAll()
            }
            _ = try await repository.commit(message: message)
            let subject = message.split(separator: "\n").first.map(String.init) ?? message
            log(.success, "Commit created: \(subject)")
            flash(files > 0 ? "Committed \(files) file\(files == 1 ? "" : "s")" : "Commit created")
            await record(.commit,
                         subject: subject,
                         detail: files > 0 ? "\(files) file\(files == 1 ? "" : "s")" : nil,
                         headBefore: headBefore)
            commitMessage = ""
            generatedMessage = nil
            pushProblem = nil
            review = nil
            inlinePath = nil
            inlineDiff = nil
            detail = nil
            applyWindowWidth()
            touchedFiles = []
            phase = .ready
            await refresh(silent: true)
            return true
        } catch {
            phase = .ready
            await handleGit(error) { [weak self] in _ = await self?.commit() }
            return false
        }
    }

    func requestPush() {
        guard let state = repo else { return }
        guard !state.detached else {
            errorMessage = "HEAD is detached. Check out a branch before pushing."
            return
        }
        guard state.ahead > 0 || (state.upstream == nil && !state.recentCommits.isEmpty) else {
            statusMessage = state.recentCommits.isEmpty
                ? "There is nothing to push yet \u{2014} this branch has no commits."
                : "Nothing to push \u{2014} origin/\(state.branch) is up to date."
            return
        }
        let subject = state.recentCommits.first?.subject ?? "(no commit yet)"
        pushRequest = PushRequest(branch: state.branchLabel,
                                  commitSubject: subject,
                                  setUpstream: state.upstream == nil,
                                  ahead: max(state.ahead, 1),
                                  behind: state.behind)
    }

    func commitAndPush() async {
        let didCommit = await commit()
        guard didCommit else { return }
        requestPush()
    }

    func performPush(_ request: PushRequest) async {
        guard let repository, let state = repo else { return }
        phase = .pushing
        pushProblem = nil
        pushSeconds = 0
        let ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.phase == .pushing else { return }
                self.pushSeconds += 1
            }
        }
        do {
            _ = try await repository.push(setUpstream: request.setUpstream, branch: state.branch)
            log(.success, "Pushed \(state.branchLabel)")
            flash("Pushed to origin/\(state.branch)")
            await record(.push,
                         subject: "origin/" + state.branch,
                         detail: request.ahead > 0
                             ? "\(request.ahead) commit\(request.ahead == 1 ? "" : "s")"
                             : nil)
            refreshForgeInBackground()
        } catch {
            // The footer keeps the reason next to the button that failed, so a
            // failed push can never look like a push that worked.
            let problem = GitFailure.describe(error)
            pushProblem = problem.full
            await record(.push, subject: "origin/" + state.branch, detail: problem.message, ok: false)
            await handleGit(error) { [weak self] in await self?.performPush(request) }
        }
        ticker.cancel()
        phase = .ready
        await refresh(silent: true)
    }

    // MARK: - Agent plumbing

    /// Why an AI action cannot run, in terms of the provider that is actually
    /// selected rather than always blaming the CLI.
    private func aiBlocker(needsFileEdits: Bool) -> String? {
        // Every prompt built after this point knows whether it may say
        // "read the files".
        CursorPrompts.canReadFiles = settings.aiProvider.canEditFiles
        if let problem = settings.aiProblem { return problem }
        if needsFileEdits, !settings.aiProvider.canEditFiles {
            return "\(settings.aiProvider.label) answers with text, so it cannot write the resolved file itself. Switch the provider to the Cursor CLI in Settings for this one."
        }
        return nil
    }

    /// Sends one prompt to whichever provider is selected.
    ///
    /// The CLI and the APIs answer the same way as far as the rest of the app
    /// is concerned: text back, events along the way. The difference that
    /// matters is that only the CLI touches files, and the call sites that
    /// need that check `aiCanEditFiles` before they get here.
    private func runAgent(prompt: String, workspace: URL, quiet: Bool = false) async throws -> AgentRunResult {
        let handler = agentEventHandler(quiet: quiet)
        switch settings.aiProvider {
        case .cursor:
            return try await agent.run(prompt: prompt,
                                       workspace: workspace,
                                       settings: agentSettings,
                                       onEvent: handler)
        case .anthropic, .openai, .compatible:
            let kind = settings.aiProvider
            guard let key = settings.key(for: kind) else {
                throw AgentError.failed("No \(kind.keyLabel) is saved. Add it in Settings.")
            }
            let engine = HTTPEngine(kind: kind,
                                    model: settings.model(for: kind),
                                    baseURL: settings.baseURL(for: kind),
                                    key: key)
            httpEngine = engine
            defer { httpEngine = nil }
            return try await engine.run(prompt: prompt, onEvent: handler)
        }
    }

    private func agentEventHandler(quiet: Bool) -> (AgentEvent) -> Void {
        let provider = settings.aiProvider.label
        return { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .started(let model, _):
                    let name = model.isEmpty ? provider : "\(provider) \u{00b7} \(model)"
                    self.log(.agent, "\(name) running")
                case .assistantText(let text):
                    if !quiet {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty && !trimmed.hasPrefix("{") {
                            self.log(.agent, String(trimmed.prefix(220)))
                        }
                    }
                case .tool(let name, let detail, let finished):
                    guard !finished else { return }
                    let suffix = detail.isEmpty ? "" : " \u{2192} " + String(detail.prefix(80))
                    self.log(.tool, name + suffix)
                case .log(let line):
                    self.log(.info, String(line.prefix(200)))
                }
            }
        }
    }

    func cancelAgent() {
        conflictLoopCancelled = true
        agent.cancel()
        httpEngine?.cancel()
        httpEngine = nil
        log(.warning, "Agent cancelled")
        agentBusyLabel = nil
        phase = .ready
    }

    private func handleAgent(error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        errorMessage = message
        log(.failure, message)
    }

    // MARK: - Discarding (always confirmed)

    func requestDiscard(_ change: FileChange) {
        pendingDiscard = DiscardRequest(changes: [change])
    }

    /// Everything in the working tree.
    func requestDiscardAll() {
        guard let state = repo, state.hasChanges else { return }
        let discardable = state.changes.filter { $0.status != .conflict }
        guard !discardable.isEmpty else {
            errorMessage = "Only conflicts are left. Resolve them instead of discarding."
            return
        }
        pendingDiscard = DiscardRequest(changes: discardable)
    }

    /// Only what is ticked in the list.
    func requestDiscardSelected() {
        guard let state = repo else { return }
        let selected = state.changes.filter { $0.staged && $0.status != .conflict }
        guard !selected.isEmpty else {
            errorMessage = "Nothing is selected."
            return
        }
        pendingDiscard = DiscardRequest(changes: selected)
    }

    /// Untracked files go to the Trash, tracked files are restored from HEAD.
    /// Only ever runs after the user confirms the dialog.
    func discard(_ request: DiscardRequest) async {
        guard let repository, let root = repo?.root, !isBusy else { return }
        var trashedCount = 0
        var restoredCount = 0

        do {
            let toTrash = request.trashed
            if !toTrash.isEmpty {
                let added = toTrash.filter { $0.status == .added }.map { $0.path }
                if !added.isEmpty {
                    try await repository.unstage(paths: added)
                }
                for change in toTrash {
                    let url = root.appendingPathComponent(change.path)
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    trashedCount += 1
                }
                log(.warning, "Moved \(trashedCount) file(s) to the Trash")
            }

            let toRestore = request.restored.map { $0.path }
            if !toRestore.isEmpty {
                try await repository.discard(paths: toRestore)
                restoredCount = toRestore.count
                log(.warning, "Discarded the changes in \(restoredCount) file(s)")
            }

            let paths = Set(request.changes.map { $0.path })
            if let selectedPath, paths.contains(selectedPath) { closeDetail() }
            if let inlinePath, paths.contains(inlinePath) {
                self.inlinePath = nil
                inlineDiff = nil
            }
            review = nil
            reviewError = nil
            await refresh(silent: true)

            let total = trashedCount + restoredCount
            if total > 0 {
                flash(total == 1 ? "Discarded 1 file" : "Discarded \(total) files")
                var parts: [String] = []
                if restoredCount > 0 { parts.append("\(restoredCount) restored to the last commit") }
                if trashedCount > 0 { parts.append("\(trashedCount) moved to the Trash") }
                await record(.discard,
                             subject: total == 1 ? "1 file" : "\(total) files",
                             detail: parts.joined(separator: ", "))
            }
        } catch {
            // Files that were already trashed or restored are gone: the
            // timeline says so even though the operation did not finish.
            let done = trashedCount + restoredCount
            if done > 0 {
                await record(.discard,
                             subject: done == 1 ? "1 file" : "\(done) files",
                             detail: "stopped partway: " + GitFailure.describe(error).message,
                             ok: false)
            }
            await handleGit(error) { [weak self] in await self?.discard(request) }
        }
    }

    /// Adds the file to .gitignore instead of discarding it over and over.
    func ignore(_ change: FileChange) async {
        guard let repository else { return }
        let pattern = ProjectSession.ignorePattern(for: change.path)
        do {
            try repository.addToGitignore(pattern)
            log(.success, "Added \(pattern) to .gitignore")
            flash("Ignoring \(pattern)")
            await refresh(silent: true)
        } catch {
            errorMessage = "Could not write .gitignore: \(error.localizedDescription)"
        }
    }

    /// Junk that appears everywhere is ignored by name, everything else by path.
    static func ignorePattern(for path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let everywhere = [".DS_Store", "Thumbs.db", "desktop.ini", ".directory"]
        return everywhere.contains(name) ? name : path
    }

    /// Hands the file to whatever the user opens this file type with.
    func revealInEditor(_ change: FileChange) {
        guard let root = repo?.root else { return }
        let url = root.appendingPathComponent(change.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = "\(change.fileName) is not on disk any more."
            return
        }
        if !NSWorkspace.shared.open(url) {
            statusMessage = "Could not open \(change.fileName)."
        }
    }

    // MARK: - Conflicts

    private func loadConflictSides(_ change: FileChange) async {
        guard let repository else { return }
        conflictCurrent = nil
        conflictIncoming = nil
        conflictCurrent = await repository.conflictSide(2, path: change.path)
        conflictIncoming = await repository.conflictSide(3, path: change.path)
    }

    /// Asks the agent to write a resolved version of the file. Nothing is staged
    /// or committed here: the user reviews the result and marks it resolved.
    func resolveConflict(_ change: FileChange) async {
        guard let state = repo else { return }
        if let blocked = aiBlocker(needsFileEdits: true) {
            errorMessage = blocked
            return
        }
        resolvingConflict = true
        agentBusyLabel = "Resolving \(change.fileName)"
        conflictResolution = nil
        log(.agent, "AI resolving conflict in \(change.path)")

        let prompt = CursorPrompts.resolveConflict(path: change.path,
                                                   current: conflictCurrent,
                                                   incoming: conflictIncoming,
                                                   state: state)
        do {
            let result = try await runAgent(prompt: prompt, workspace: state.root)
            conflictResolution = result.text
            log(.success, "AI proposed a resolution for \(change.fileName)")
        } catch {
            handleAgent(error: error)
        }
        agentBusyLabel = nil
        resolvingConflict = false
        await refresh(silent: true)
        if let updated = repo?.changes.first(where: { $0.path == change.path }) {
            await loadDiff(for: updated)
        }
    }

    /// Marks a resolved conflict as done by staging it. Never commits.
    func markResolved(_ change: FileChange) async {
        guard let repository else { return }
        do {
            try await repository.stage(paths: [change.path])
            log(.success, "Marked \(change.fileName) as resolved")
            await refresh(silent: true)
            closeDetail()
        } catch {
            await handleGit(error) { [weak self] in await self?.markResolved(change) }
        }
    }

    // MARK: - Git failures

    /// Turns a git failure into something actionable. Lock contention gets its
    /// own dialog, because the only safe fix is a decision by the user.
    private func handleGit(_ error: Error, retry: @escaping () async -> Void) async {
        let problem = GitFailure.describe(error)
        if let command = problem.command {
            log(.failure, "git \(command) \u{2014} \(problem.message)")
        } else {
            log(.failure, problem.message)
        }
        // Kept so the user can hand exactly this to the agent instead of
        // reading git's output and working it out themselves.
        failure = AIFailure(command: problem.command,
                            message: problem.message,
                            raw: problem.raw.isEmpty ? problem.full : problem.raw)

        guard problem.isLockContention, let repository else {
            errorMessage = problem.full
            return
        }

        var detail = problem.hint ?? ""
        var canRemove = false
        var path: String?
        var stoppable: [Int32] = []
        if let info = await repository.lockInfo(at: GitFailure.lockPath(in: problem.raw)) {
            path = info.path
            canRemove = info.looksStale
            stoppable = info.ourHolders.map { $0.pid }
            detail = "The lock file is \(info.ageText). \(info.explanation)\n\n\(info.path)"
            log(.warning, info.holders.isEmpty
                ? "index.lock with no owner, \(info.ageText)"
                : "index.lock held by " + info.holders.map { $0.label }.joined(separator: ", "))
        }
        lockAlert = LockAlert(detail: detail,
                              lockPath: path,
                              canRemove: canRemove,
                              stoppable: stoppable,
                              retry: retry)
    }

    func retryAfterLock(_ alert: LockAlert) async {
        lockAlert = nil
        await refresh(silent: true)
        await alert.retry()
    }

    /// Stops the app's own stuck git command (a hook that never finished, most
    /// of the time), clears the lock it left and runs the operation again.
    func stopLockHolders(_ alert: LockAlert) async {
        guard let repository, !alert.stoppable.isEmpty else { return }
        lockAlert = nil
        log(.warning, "Stopping \(alert.stoppable.count) process(es) started by Git Agent")
        await GitRepository.stop(alert.stoppable)
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        if let path = alert.lockPath, let info = await repository.lockInfo(at: path) {
            if info.isHeld {
                let names = info.realHolders.map { $0.label }.joined(separator: ", ")
                log(.failure, "It did not stop: \(names)")
                errorMessage = "\(names) is still holding the lock. Close it from Activity Monitor, or quit the app that started it."
                await refresh(silent: true)
                return
            }
            if info.probed {
                try? await repository.removeLock(at: path)
                log(.warning, "Removed the lock it left behind")
            }
        }
        await refresh(silent: true)
        await alert.retry()
    }

    /// Deletes the leftover lock file, then runs the operation again.
    func removeLock(_ alert: LockAlert) async {
        guard let repository, let path = alert.lockPath else { return }
        lockAlert = nil
        do {
            try await repository.removeLock(at: path)
            log(.warning, "Removed the leftover lock file \((path as NSString).lastPathComponent)")
            await refresh(silent: true)
            await alert.retry()
        } catch {
            let message = "Could not remove the lock file: \(error.localizedDescription)"
            errorMessage = message
            log(.failure, message)
        }
    }

    // MARK: - Timeline

    /// Writes one line in this project's timeline. The log is on disk, so the
    /// timeline survives a restart.
    private func record(_ operation: GitOperation,
                        subject: String,
                        detail: String? = nil,
                        headBefore: String? = nil,
                        ok: Bool = true) async {
        // Reading HEAD again is only worth it for an operation that moved it.
        let headAfter = operation.movesHead ? await repository?.head() : nil
        let branch = repo?.branch
        let entry = OperationRecord(operation: operation,
                                    subject: subject,
                                    detail: detail,
                                    headBefore: headBefore,
                                    headAfter: headAfter,
                                    branch: (branch?.isEmpty == false) ? branch : nil,
                                    ok: ok)
        let result = await operations.append(entry)
        timeline = result.records
        if !result.saved && !warnedAboutTimeline {
            warnedAboutTimeline = true
            log(.warning, "The timeline could not be written to disk, so it will be lost when the app quits.")
        }
    }

    /// Where HEAD is right now, captured before an operation that will move it.
    private func headSnapshot() async -> String? {
        return await repository?.head()
    }

    // MARK: - Activity log

    func log(_ kind: ActivityKind, _ text: String) {
        agentActivity.append(ActivityLine(kind: kind, text: text))
        if agentActivity.count > 300 { agentActivity.removeFirst(agentActivity.count - 300) }
    }

}

// MARK: - Commit message cleanup

enum CommitMessageCleaner {
    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let inner = lines.dropFirst().filter { !$0.hasPrefix("```") }
            text = inner.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasPrefix("\"") && text.hasSuffix("\"") && text.count > 2 {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Defaults

enum Defaults {
    private static let store = UserDefaults.standard

    static func bool(_ key: String, _ fallback: Bool) -> Bool {
        return store.object(forKey: key) as? Bool ?? fallback
    }
    static func string(_ key: String, _ fallback: String) -> String {
        return store.string(forKey: key) ?? fallback
    }
    static func array(_ key: String) -> [String] {
        return store.stringArray(forKey: key) ?? []
    }
    static func int(_ key: String, _ fallback: Int) -> Int {
        return store.object(forKey: key) as? Int ?? fallback
    }
    static func set(_ key: String, _ value: Bool) { store.set(value, forKey: key) }
    static func set(_ key: String, _ value: String) { store.set(value, forKey: key) }
    static func set(_ key: String, _ value: [String]) { store.set(value, forKey: key) }
    static func set(_ key: String, _ value: Int) { store.set(value, forKey: key) }
}
