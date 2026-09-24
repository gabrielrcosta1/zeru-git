import SwiftUI

/// The expanded half of the window. Only exists while something is open.
struct DetailPanel: View {
    @EnvironmentObject private var state: ProjectSession

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: title, subtitle: subtitle) {
                state.closeDetail()
            }
            Hairline()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var content: some View {
        if let target = state.detail {
            switch target {
            case .allChanges, .file:
                DiffView(diff: state.fileDiff, loading: state.loadingDiff)
            case .problem(let id):
                if let problem = state.problem(with: id) {
                    ProblemDetail(problem: problem)
                } else {
                    PanelPlaceholder(text: "This issue is no longer available.")
                }
            case .conflict(let path):
                if let change = state.repo?.changes.first(where: { $0.path == path }) {
                    ConflictPanel(change: change)
                } else {
                    PanelPlaceholder(text: "This conflict is resolved.")
                }
            case .activity:
                ActivityView()
            case .stashes:
                StashPanel()
            case .recovery:
                RecoveryPanel()
            case .rebase:
                RebasePanel()
            case .forge:
                ForgePanel()
            case .plan:
                PlanPanel()
            case .workflows:
                WorkflowsPanel()
            case .workflowEditor:
                WorkflowEditor()
            case .workflowRun:
                WorkflowRunPanel()
            case .chat:
                ChatPanel()
            case .sync:
                SyncPanel()
            case .commit(let sha):
                CommitPanel(sha: sha)
            }
        }
    }

    private var title: String {
        guard let target = state.detail else { return "" }
        switch target {
        case .allChanges:
            return "All changes"
        case .file(let path):
            return (path as NSString).lastPathComponent
        case .problem(let id):
            return state.problem(with: id)?.title ?? "Issue"
        case .conflict(let path):
            return (path as NSString).lastPathComponent
        case .activity:
            return "Activity"
        case .stashes:
            return "Stashes"
        case .recovery:
            return "Recovery"
        case .rebase:
            return "Reorganize commits"
        case .forge:
            return state.forge?.kind.name ?? "Pull requests"
        case .plan:
            return "What the agent suggests"
        case .chat:
            return "Ask the agent"
        case .sync:
            return "Sync & Pull"
        case .workflows:
            return "Workflows"
        case .workflowEditor:
            return state.workflows.draftIsNew ? "Create workflow" : "Edit workflow"
        case .workflowRun:
            return state.workflows.visibleRun?.workflowName
                ?? state.workflows.prepared?.workflow.name
                ?? "Workflow"
        case .commit(let sha):
            return state.commitDetail?.subject ?? String(sha.prefix(7))
        }
    }

    private var subtitle: String? {
        guard let target = state.detail else { return nil }
        switch target {
        case .allChanges:
            let count = state.repo?.changes.count ?? 0
            return "\(count) file\(count == 1 ? "" : "s")"
        case .file(let path), .conflict(let path):
            let directory = (path as NSString).deletingLastPathComponent
            return directory.isEmpty ? nil : directory
        case .problem(let id):
            return state.problem(with: id)?.location
        case .activity:
            switch state.activityMode {
            case .timeline:
                return "What happened to this repository"
            case .log:
                return "Everything Git Agent and the agent did"
            }
        case .stashes:
            guard state.stashesLoaded else { return nil }
            let count = state.stashes.count
            return count == 1 ? "1 entry" : "\(count) entries"
        case .recovery:
            guard let repo = state.repo, !repo.detached else { return nil }
            return "Where " + repo.branchLabel + " has been"
        case .rebase:
            guard let plan = state.rebasePlan else { return nil }
            return plan.branch + " \u{00b7} " + plan.summary
        case .forge:
            return state.forge.map { $0.slug } ?? nil
        case .plan:
            // A plan from the chat answers a question, not a failure.
            return state.planQuestion ?? state.failure?.commandLabel
        case .chat:
            return state.aiProviderLabel
        case .sync:
            return state.sync.run?.upstream ?? state.repo?.upstream ?? state.repo?.branchLabel
        case .workflows:
            let count = state.workflows.workflows.count
            return count == 1 ? "1 workflow" : "\(count) workflows"
        case .workflowEditor:
            return state.workflows.draft?.name.isEmpty == false ? state.workflows.draft?.name : nil
        case .workflowRun:
            if let run = state.workflows.visibleRun { return run.flowLabel }
            return state.workflows.prepared.map { $0.workflow.flowLabel(values: $0.values) }
        case .commit(let sha):
            guard let commit = state.commitDetail, commit.sha == sha else {
                return String(sha.prefix(7))
            }
            return commit.shortSha + " \u{00b7} " + commit.author + " \u{00b7} " + commit.relativeDate
        }
    }
}

// MARK: - Header

struct PanelHeader: View {
    let title: String
    let subtitle: String?
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.bodyEmphasis)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.micro)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 6)
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close panel (\u{2318}0)")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }
}

struct PanelPlaceholder: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Problem

struct ProblemDetail: View {
    let problem: AIProblem
    @EnvironmentObject private var state: ProjectSession

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Pill(text: problem.severity.label.lowercased(),
                         color: Theme.tint(for: problem.severity))
                    if let location = problem.location {
                        Text(location)
                            .font(Theme.mono)
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 4)
                }

                if !problem.detail.isEmpty {
                    Text(problem.detail)
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !state.touchedFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Image(systemName: "pencil")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.accentColor)
                            Text("AI changed \(state.touchedFiles.count) file\(state.touchedFiles.count == 1 ? "" : "s")")
                                .font(Theme.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(state.touchedFiles, id: \.self) { file in
                            Text(file)
                                .font(Theme.micro)
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                        if let report = state.lastAgentReport, !report.isEmpty {
                            Text(report)
                                .font(Theme.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2)
                        }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.surface)
                    )
                }

                HStack(spacing: 10) {
                    if problem.kind.isIssue {
                    ActionButton(title: "Fix with AI",
                                 icon: Theme.aiMark,
                                 prominent: true,
                                 busy: state.phase == .fixing) {
                        Task { await state.fix(problem: problem) }
                    }
                    .disabled(state.isBusy || !state.aiCanEditFiles)
                    .help(state.aiCanEditFiles
                          ? "Asks the agent to fix this"
                          : (state.aiProblem ?? "\(state.aiProviderLabel) cannot write files"))
                    }

                    if state.phase == .fixing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                            Text(state.agentActivity.last?.text ?? "Working\u{2026}")
                                .font(Theme.micro)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(14)

            Hairline()
            DiffView(diff: state.fileDiff, loading: state.loadingDiff)
        }
    }
}

// MARK: - One commit

/// A commit opened from the palette: what it says, and everything it changed.
struct CommitPanel: View {
    let sha: String
    @EnvironmentObject private var state: ProjectSession

    var body: some View {
        VStack(spacing: 0) {
            if let commit = state.commitDetail, commit.sha == sha {
                VStack(alignment: .leading, spacing: 6) {
                    Text(commit.subject)
                        .font(Theme.bodyEmphasis)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 7) {
                        Text(commit.sha)
                            .font(Theme.mono)
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(commit.author)
                            .font(Theme.micro)
                            .foregroundStyle(.tertiary)
                        Text(commit.relativeDate)
                            .font(Theme.micro)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                Hairline()
            }
            DiffView(diff: state.commitDiff, loading: state.loadingCommitDiff)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
