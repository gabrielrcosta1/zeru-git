import AppKit
import SwiftUI

/// Draggable strip that leaves room for the traffic lights and carries the two
/// window level controls: add a project, and the actions menu.
struct TitleStrip: View {
    @EnvironmentObject private var workspace: Workspace
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 2) {
            Spacer(minLength: 0)

            if settings.floatOnTop {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .help("Floating on top")
                    .padding(.trailing, 4)
            }

            Button {
                workspace.chooseProject()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open another project (\u{2318}O)")

            ActionsMenu()
        }
        .padding(.leading, 74)
        .padding(.trailing, 12)
        .frame(height: 30)
        .contentShape(Rectangle())
    }
}

struct ProjectBlock: View {
    @EnvironmentObject private var state: ProjectSession
    @State private var hoveringBranch = false
    @State private var hoveringStash = false

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            ProjectMark(name: state.projectName)

            VStack(alignment: .leading, spacing: 3) {
                Text(state.projectName.isEmpty ? "Git Agent" : state.projectName)
                    .font(Theme.projectTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let repo = state.repo {
                    HStack(spacing: 6) {
                        Button {
                            // A click on the anchor already dismisses the
                            // popover, so only ever present here.
                            if !state.branchPickerOpen { state.branchPickerOpen = true }
                        } label: {
                            BranchChip(name: repo.branchLabel,
                                       sync: repo.syncLabel,
                                       interactive: true,
                                       hovering: hoveringBranch)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { value in
                            withAnimation(Theme.snap) { hoveringBranch = value }
                        }
                        .help("Switch branch (\u{2318}B)")
                        .popover(isPresented: $state.branchPickerOpen, arrowEdge: .bottom) {
                            BranchPicker()
                                .environmentObject(state)
                        }

                        Text("\u{00b7}")
                            .font(Theme.caption)
                            .foregroundStyle(.tertiary)

                        Text(changeSummary(repo))
                            .font(Theme.caption)
                            .foregroundStyle(repo.hasChanges ? .secondary : .tertiary)

                        if state.stashCount > 0 {
                            Text("\u{00b7}")
                                .font(Theme.caption)
                                .foregroundStyle(.tertiary)
                            Button {
                                Task { await state.openStashes() }
                            } label: {
                                Text("\(state.stashCount) stashed")
                                    .font(Theme.micro)
                                    .foregroundStyle(hoveringStash ? .secondary : .tertiary)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { value in
                                withAnimation(Theme.snap) { hoveringStash = value }
                            }
                            .help("Open the stash manager (\u{2318}3)")
                        }
                    }
                }
            }
            Spacer(minLength: 8)

            SyncButton()

            OpenInMenu()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    private func changeSummary(_ repo: RepoState) -> String {
        if !repo.hasChanges { return "no changes" }
        let count = repo.changes.count
        return "\(count) change\(count == 1 ? "" : "s")"
    }
}

// MARK: - Sync

/// Sync & Pull, with a permanent home.
///
/// It also lives in the banner above the commit box, but that banner is
/// replaced by the push-failure bar, and a button that disappears exactly when
/// the push was rejected is worse than no button. This one is always here.
struct SyncButton: View {
    @EnvironmentObject private var state: ProjectSession
    @State private var hovering = false

    private var behind: Int { return state.repo?.behind ?? 0 }

    var body: some View {
        Button {
            state.syncAndPull()
        } label: {
            HStack(spacing: 3) {
                if state.sync.running {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10.5, weight: .medium))
                }
                if behind > 0 {
                    Text("\(behind)")
                        .font(Theme.micro)
                }
            }
            .foregroundStyle(behind > 0 ? Theme.warn : (hovering ? .primary : .secondary))
            .frame(height: 20)
            .padding(.horizontal, behind > 0 ? 5 : 0)
            .frame(minWidth: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.repo == nil || state.isBusy)
        .onHover { value in
            withAnimation(Theme.snap) { hovering = value }
        }
        .help(behind > 0
              ? "Sync & Pull \u{2014} \(behind) commit\(behind == 1 ? "" : "s") to bring in, your uncommitted work is kept (\u{21e7}\u{2318}S)"
              : "Sync & Pull \u{2014} fetch and bring this branch up to date (\u{21e7}\u{2318}S)")
    }
}

// MARK: - Open in

/// Opens the whole project folder in whichever editor the user keeps it in.
/// The last one used comes first, so the usual case is one click and one more.
struct OpenInMenu: View {
    @EnvironmentObject private var state: ProjectSession

    var body: some View {
        Menu {
            // The host first: "open it there, it is easier" is the most common
            // reason to leave this window.
            if let web = state.web {
                Button(web.label(for: .repo)) { state.openOnWeb(.repo) }
                Button(web.label(for: .branch(""))) { state.openBranchOnWeb() }
                Button(web.label(for: .requests)) { state.openOnWeb(.requests) }
                Button(web.label(for: .actions)) { state.openOnWeb(.actions) }
                Divider()
            }
            ForEach(ordered) { editor in
                Button(editor.name) { state.openProject(in: editor) }
            }
            if !ordered.isEmpty { Divider() }
            Button("Reveal in Finder") { state.revealProjectInFinder() }
        } label: {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(state.web == nil
              ? "Open this project in an editor"
              : "Open this project on \(state.web?.kind.name ?? "the web"), or in an editor")
    }

    private var ordered: [Editor] {
        let all = Editors.installed()
        guard let first = state.preferredEditor else { return all }
        return [first] + all.filter { $0.id != first.id }
    }
}

// MARK: - Actions menu

struct ActionsMenu: View {
    @EnvironmentObject private var workspace: Workspace
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Menu {
            Button("Search\u{2026}") { workspace.paletteOpen = true }
                .disabled(workspace.active?.repo == nil)

            Divider()

            Button("Open Project\u{2026}") { workspace.chooseProject() }

            Menu("Open Recent") {
                ForEach(workspace.recentProjects, id: \.self) { path in
                    Button((path as NSString).lastPathComponent) {
                        Task { await workspace.open(url: URL(fileURLWithPath: path, isDirectory: true)) }
                    }
                }
            }
            .disabled(workspace.recentProjects.isEmpty)

            Divider()

            // Everything that talks to the remote, in one place.
            Group {
                Button("Fetch") {
                    Task { await workspace.active?.fetchRemote(silent: false) }
                }
                .disabled(workspace.active == nil || workspace.active?.fetching == true || workspace.active?.isBusy == true)

                Button("Sync & Pull\u{2026}") { workspace.active?.syncAndPull() }
                    .disabled(workspace.active?.repo == nil || workspace.active?.isBusy == true)

                Button(pullTitle) { Task { await workspace.active?.pull() } }
                    .disabled(workspace.active?.repo?.upstream == nil || workspace.active?.isBusy == true)

                Button("Push\u{2026}") { workspace.active?.requestPush() }
                    .disabled(workspace.active == nil || workspace.active?.isBusy == true)

                Divider()

                Button("Stash changes") { Task { await workspace.active?.stashChanges() } }
                    .disabled(workspace.active?.repo?.hasChanges != true || workspace.active?.isBusy == true)

                Button(popTitle) { Task { await workspace.active?.popStash() } }
                    .disabled((workspace.active?.stashCount ?? 0) == 0 || workspace.active?.isBusy == true)

                Button(stashesTitle) { Task { await workspace.active?.openStashes() } }
                    .disabled(workspace.active?.repo == nil)

                if workspace.active?.repo?.isRebasing == true {
                    Button("Abort rebase") { Task { await workspace.active?.abortRebase() } }
                }
            }

            Group {
                Divider()

                Button("Refresh") { Task { await workspace.active?.refresh() } }
                    .disabled(workspace.active == nil)
                Button("Select All Changes") { Task { await workspace.active?.stageAll() } }
                    .disabled(workspace.active?.repo?.hasChanges != true)
                Button("Discard All Changes\u{2026}") { workspace.active?.requestDiscardAll() }
                    .disabled(workspace.active?.repo?.hasChanges != true || workspace.active?.isBusy == true)
                // The panels get a group of their own: a builder takes ten
                // children and this list keeps growing.
                Group {
                    Button("Show All Changes") { Task { await workspace.active?.openAllChanges() } }
                        .disabled(workspace.active?.repo?.hasChanges != true)
                    Button("Activity") { workspace.active?.openActivity() }
                        .disabled(workspace.active == nil)
                    Button(recoveryTitle) { Task { await workspace.active?.openRecovery() } }
                        .disabled(workspace.active?.repo == nil)
                    Button("Reorganize Commits\u{2026}") { Task { await workspace.active?.openRebase() } }
                        .disabled(workspace.active?.repo == nil || workspace.active?.isBusy == true)
                    Button(forgeTitle) { Task { await workspace.active?.openForge() } }
                        .disabled(workspace.active?.repo == nil)
                    Button("Workflows\u{2026}") { workspace.active?.openWorkflows() }
                        .disabled(workspace.active?.repo == nil)
                    Button("Ask the Agent\u{2026}") { workspace.active?.openChat() }
                        .disabled(workspace.active?.repo == nil)
                    Button(webTitle) { workspace.active?.openOnWeb(.repo) }
                        .disabled(workspace.active?.web == nil)
                    Button("Reveal in Finder") { workspace.active?.revealProjectInFinder() }
                        .disabled(workspace.active == nil)
                }
            }

            Group {
                Divider()

                // The error bar is cleared by the next refresh; the last
                // failure is not, so there is always a way back to it.
                if let session = workspace.active, session.failure != nil {
                    Button(session.plan == nil
                           ? "Fix the Last Failure with AI\u{2026}"
                           : "What the Agent Suggests\u{2026}") {
                        Task {
                            if session.plan == nil {
                                await session.fixFailureWithAI()
                            } else {
                                session.detail = .plan
                                session.applyWindowWidth()
                            }
                        }
                    }
                    .disabled(session.isBusy || !session.aiAvailable)
                }

                Toggle("Float on Top", isOn: Binding(get: { settings.floatOnTop },
                                                     set: { settings.floatOnTop = $0 }))
                Button("Settings\u{2026}") { AppActions.openSettings() }

                Divider()

                Button("Close Project") { workspace.closeActive() }
                    .disabled(workspace.active == nil)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Actions")
    }

    private var webTitle: String {
        guard let name = workspace.active?.web?.kind.name else { return "Open on the web\u{2026}" }
        return "Open on \(name)\u{2026}"
    }

    private var pullTitle: String {
        let behind = workspace.active?.repo?.behind ?? 0
        return behind > 0 ? "Pull \(behind) commit\(behind == 1 ? "" : "s")" : "Pull"
    }

    private var forgeTitle: String {
        guard let pr = workspace.active?.forgePR, pr.isOpen else {
            return workspace.active?.forge?.kind.name.appending("\u{2026}") ?? "Pull Requests\u{2026}"
        }
        return "Pull Request #\(pr.number)\u{2026}"
    }

    private var recoveryTitle: String {
        return workspace.active?.recoveryBanner == nil ? "Recovery\u{2026}" : "Recovery \u{2014} commits removed\u{2026}"
    }

    private var stashesTitle: String {
        let count = workspace.active?.stashCount ?? 0
        return count > 0 ? "Stashes (\(count))\u{2026}" : "Stashes\u{2026}"
    }

    private var popTitle: String {
        let count = workspace.active?.stashCount ?? 0
        return count > 1 ? "Pop stash (\(count))" : "Pop stash"
    }
}

enum AppActions {
    /// The one settings object, handed over by the workspace at launch so any
    /// view can open the window without threading it through the hierarchy.
    @MainActor static weak var settings: AppSettings?

    @MainActor
    static func openSettings() {
        guard let settings else { return }
        SettingsWindow.shared.show(settings: settings)
    }
}
