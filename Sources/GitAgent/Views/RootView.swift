import AppKit
import SwiftUI

/// The window: title strip, tabs when there is more than one project, and the
/// active project below it.
struct RootView: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            TitleStrip()

            if workspace.tabs.count > 1 {
                TabBar()
                Hairline()
            }

            content

            if let message = workspace.openError {
                MessageBar(text: message, isError: true, onDismiss: { workspace.openError = nil })
            }
        }
        .frame(minWidth: ProjectSession.compactWidth, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowAccessor { window in workspace.adopt(window) })
        .overlay {
            if workspace.paletteOpen, let active = workspace.active {
                CommandPalette(session: active)
                    .environmentObject(active)
                    // Identity follows the project, so switching tabs while the
                    // palette is open re-reads that project's branches and
                    // files instead of showing the previous one's empty lists.
                    .id(active.id)
                    .transition(.opacity)
            }
        }
        .animation(Theme.snap, value: workspace.paletteOpen)
    }

    @ViewBuilder private var content: some View {
        if let active = workspace.active {
            ProjectWindow(session: active)
                .environmentObject(active)
                .id(active.id)
        } else {
            NoProjectView()
        }
    }
}

// MARK: - One project

struct ProjectWindow: View {
    @ObservedObject var session: ProjectSession

    var body: some View {
        HStack(spacing: 0) {
            CompactColumn()
                .frame(minWidth: 356,
                       maxWidth: session.detail == nil ? .infinity : ProjectSession.compactWidth)

            if session.detail != nil {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 1)
                DetailPanel()
                    .frame(minWidth: 420, maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.16), value: session.detail)
        .alert("Push to origin?",
               isPresented: Binding(get: { session.pushRequest != nil },
                                    set: { if !$0 { session.pushRequest = nil } }),
               presenting: session.pushRequest) { request in
            Button("Cancel", role: .cancel) { session.pushRequest = nil }
            Button("Commit & Push") {
                let pending = request
                session.pushRequest = nil
                Task { await session.performPush(pending) }
            }
        } message: { request in
            Text(pushMessage(request))
        }
        .background(discardAlertLayer)
        .background(stashDropAlertLayer)
        .background(moveBackAlertLayer)
        .background(rebaseAlertLayer)
        .background(planStepAlertLayer)
        .background(lockAlertLayer)
        .background(blockedSwitchAlertLayer)
    }

    // MARK: Alerts

    /// Untracked files standing in the way of a branch switch. Stashing them
    /// is not destructive, so this asks once and does it.
    @ViewBuilder private var blockedSwitchAlertLayer: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .alert(session.blockedSwitch?.title ?? "Files are in the way",
                   isPresented: Binding(get: { session.blockedSwitch != nil },
                                        set: { if !$0 { session.blockedSwitch = nil } }),
                   presenting: session.blockedSwitch) { blocked in
                Button("Cancel", role: .cancel) { session.blockedSwitch = nil }
                Button("Stash them and switch") {
                    let pending = blocked
                    session.blockedSwitch = nil
                    Task { await session.stashAndSwitch(pending) }
                }
            } message: { blocked in
                Text(blocked.message)
            }
    }

    @ViewBuilder private var discardAlertLayer: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .alert(session.pendingDiscard?.title ?? "Discard changes?",
                   isPresented: Binding(get: { session.pendingDiscard != nil },
                                        set: { if !$0 { session.pendingDiscard = nil } }),
                   presenting: session.pendingDiscard) { request in
                Button("Cancel", role: .cancel) { session.pendingDiscard = nil }
                Button(request.confirmTitle, role: .destructive) {
                    let pending = request
                    session.pendingDiscard = nil
                    Task { await session.discard(pending) }
                }
            } message: { request in
                Text(request.message)
            }
    }

    @ViewBuilder private var stashDropAlertLayer: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .alert("Drop this stash?",
                   isPresented: Binding(get: { session.pendingStashDrop != nil },
                                        set: { if !$0 { session.pendingStashDrop = nil } }),
                   presenting: session.pendingStashDrop) { entry in
                Button("Cancel", role: .cancel) { session.pendingStashDrop = nil }
                Button("Drop", role: .destructive) {
                    let pending = entry
                    session.pendingStashDrop = nil
                    Task { await session.dropStash(pending) }
                }
            } message: { entry in
                Text(dropMessage(entry))
            }
    }

    @ViewBuilder private var planStepAlertLayer: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .alert("Run this command?",
                   isPresented: Binding(get: { session.pendingStep != nil },
                                        set: { if !$0 { session.pendingStep = nil } }),
                   presenting: session.pendingStep) { step in
                Button("Skip", role: .cancel) {
                    let pending = step
                    session.skipPendingStep(pending)
                }
                Button("Run It", role: .destructive) {
                    let pending = step
                    Task { await session.confirmPendingStep(pending) }
                }
            } message: { step in
                Text(stepMessage(step))
            }
    }

    @ViewBuilder private var rebaseAlertLayer: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .alert("Replay these commits?",
                   isPresented: Binding(get: { session.pendingRebase != nil },
                                        set: { if !$0 { session.pendingRebase = nil } }),
                   presenting: session.pendingRebase) { plan in
                Button("Cancel", role: .cancel) { session.pendingRebase = nil }
                Button("Start Rebase") {
                    let pending = plan
                    session.pendingRebase = nil
                    Task { await session.runRebase(pending) }
                }
            } message: { plan in
                Text(rebaseMessage(plan))
            }
    }

    @ViewBuilder private var moveBackAlertLayer: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .alert("Move the branch back?",
                   isPresented: Binding(get: { session.pendingRecoveryReset != nil },
                                        set: { if !$0 { session.pendingRecoveryReset = nil } }),
                   presenting: session.pendingRecoveryReset) { point in
                Button("Cancel", role: .cancel) { session.pendingRecoveryReset = nil }
                Button("Move \(point.branch) Back") {
                    let pending = point
                    session.pendingRecoveryReset = nil
                    Task { await session.moveBranchBack(pending) }
                }
            } message: { point in
                Text(moveBackMessage(point))
            }
    }

    @ViewBuilder private var lockAlertLayer: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .alert("Another process is using this repository",
                   isPresented: Binding(get: { session.lockAlert != nil },
                                        set: { if !$0 { session.lockAlert = nil } }),
                   presenting: session.lockAlert) { alert in
                Button("Try Again") {
                    let pending = alert
                    Task { await session.retryAfterLock(pending) }
                }
                if !alert.stoppable.isEmpty {
                    Button("Stop It & Retry", role: .destructive) {
                        let pending = alert
                        Task { await session.stopLockHolders(pending) }
                    }
                }
                if alert.canRemove {
                    Button("Remove Lock File", role: .destructive) {
                        let pending = alert
                        Task { await session.removeLock(pending) }
                    }
                }
                Button("Cancel", role: .cancel) { session.lockAlert = nil }
            } message: { alert in
                Text(alert.detail)
            }
    }

    // MARK: Copy

    private func stepMessage(_ step: GitCommandStep) -> String {
        var text = step.display + "\n\n"
        if !step.why.isEmpty { text += "The agent's reason: " + step.why + "\n\n" }
        text += "Git Agent classified this as something that can lose work, so it does not run on its own. "
        text += "Skipping it carries on with the rest of the plan.\n\n"
        // The reflog is a local thing. Saying it covers a push, or a dropped
        // stash, would be a comforting lie.
        switch step.arguments.first {
        case "push":
            text += "This one publishes to the remote, and the reflog does not cover that: undoing it afterwards is a conversation with whoever else has pulled."
        case "stash":
            text += "The stash commit stays reachable by its sha for a while, so it is recoverable, but it leaves the stash list."
        default:
            text += "Whatever it moves on this branch stays in the reflog, so Recovery (\u{2318}4) is the way back."
        }
        return text
    }

    private func rebaseMessage(_ plan: RebasePlan) -> String {
        var text = "\(plan.branch) is rewritten from \(plan.base.label): \(plan.summary).\n\n"
        text += plan.actionSummary.prefix(1).uppercased() + plan.actionSummary.dropFirst() + ".\n\n"
        text += "Every commit here is one the upstream does not have, so no force push is needed. "
        text += "The commits being replaced stay in the reflog, so Recovery can put the branch straight back.\n\n"
        text += "If a replay hits a conflict the rebase stops and waits, and Abort rebase returns you here."
        return text
    }

    private func moveBackMessage(_ point: RecoveryPoint) -> String {
        var text = "\(point.branch) goes back from \(point.entry.shortSha) to \(point.shortFrom), "
        text += "undoing the \(point.entry.action).\n\n"
        if point.isLoss {
            let names = point.lost.prefix(3).map { $0.shortSha + " " + $0.subject }.joined(separator: "\n")
            text += "Back on the branch:\n\(names)"
            if point.lost.count > 3 || point.moreLost {
                text += "\nand more"
            }
            text += "\n\n"
        }
        text += "Uncommitted work is kept \u{2014} git refuses the move rather than overwrite it \u{2014} "
        text += "but anything you had staged comes back unstaged.\n\n"
        text += "Where the branch is now stays in the reflog, so this can be undone too."
        return text
    }

    private func dropMessage(_ entry: GitStashEntry) -> String {
        var text = "\(entry.ref) \u{2014} \(entry.title)\n\(entry.when)\n\n"
        text += "It leaves the stash list without being applied. "
        text += "The commit stays reachable for a while, so it can still be recovered with:\n\n"
        text += "git stash apply \(entry.shortSha)"
        return text
    }

    private func pushMessage(_ request: PushRequest) -> String {
        var text = "Commit\n\(request.commitSubject)\n\nBranch\n\(request.branch)\n\n"
        if request.behind > 0 {
            text += "origin/\(request.branch) has \(request.behind) commit"
            text += request.behind == 1 ? "" : "s"
            text += " that you do not have, so git will reject this push. "
            text += "Integrate them first:\n\ngit pull --rebase origin \(request.branch)"
        } else if request.setUpstream {
            text += "This branch has no upstream yet, it will be created as origin/\(request.branch)."
        } else {
            text += "You're about to push \(request.ahead) commit"
            text += request.ahead == 1 ? "" : "s"
            text += " to origin/\(request.branch)."
        }
        return text
    }
}

// MARK: - Compact column

struct CompactColumn: View {
    @EnvironmentObject private var state: ProjectSession

    var body: some View {
        VStack(spacing: 0) {
            if state.repo == nil {
                LoadingProjectView(name: state.projectName)
            } else {
                ProjectBlock()

                if let busy = state.busyLabel, state.phase != .reviewing {
                    // Only agent work can be cancelled: killing a git command
                    // mid flight is not something the app offers.
                    BusyBar(label: busy,
                            onCancel: state.agentBusyLabel == nil ? nil : { state.cancelAgent() })
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        SummaryStrip()
                        ForgeChip()
                        RecoveryBanner()
                        if state.repo?.hasConflicts == true {
                            ConflictBanner()
                        }
                        AIReviewCard()
                        ChangesSection()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 18)
                }

                CommitFooter()
            }

            if let message = state.errorMessage {
                MessageBar(text: message,
                           isError: true,
                           fixTitle: state.failure == nil ? nil : "Fix with AI",
                           fixBusy: state.phase == .fixing,
                           onFix: state.failure == nil || !state.aiAvailable ? nil : {
                               Task { await state.fixFailureWithAI() }
                           },
                           onDismiss: {
                               state.errorMessage = nil
                               state.clearFailure()
                           })
            } else if let message = state.statusMessage {
                MessageBar(text: message, isError: false, onDismiss: { state.statusMessage = nil })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct LoadingProjectView: View {
    let name: String

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text(name.isEmpty ? "Opening\u{2026}" : "Opening \(name)\u{2026}")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Bars

struct BusyBar: View {
    let label: String
    let onCancel: (() -> Void)?

    var body: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 12, height: 12)
            Text(label)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let onCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.link)
                    .font(Theme.micro)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Theme.surface)
    }
}

struct MessageBar: View {
    let text: String
    let isError: Bool
    /// Offered next to a git failure the agent can be asked about.
    var fixTitle: String?
    var fixBusy: Bool = false
    var onFix: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(isError ? Theme.bad : Color.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 7) {
                Text(text)
                    .font(Theme.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let onFix, let fixTitle {
                    ActionButton(title: fixTitle,
                                 icon: Theme.aiMark,
                                 prominent: true,
                                 busy: fixBusy,
                                 action: onFix)
                }
            }
            Spacer(minLength: 4)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isError ? Theme.bad.opacity(0.09) : Theme.surface)
    }
}
