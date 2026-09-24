import SwiftUI

struct ChangesPane: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let repo = state.repo {
                SectionLabel(text: repo.hasConflicts ? "Conflicts & Changes" : "Changes",
                             trailing: repo.hasChanges ? "+\(repo.totalAdditions) \u{2212}\(repo.totalDeletions)" : nil)

                if !repo.hasChanges {
                    CleanTreeView(repo: repo)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            AllChangesRow(selected: state.selectedPath == nil,
                                          count: repo.changes.count) {
                                Task { await state.selectAllChanges() }
                            }
                            ForEach(repo.changes) { change in
                                ChangeRow(change: change,
                                          selected: state.selectedPath == change.path) {
                                    Task { await state.select(change: change) }
                                } onToggleStage: {
                                    Task { await state.toggleStage(change) }
                                }
                            }
                        }
                        .padding(.bottom, 4)
                    }

                    HStack(spacing: 8) {
                        Text("\(repo.stagedChanges.count) staged")
                            .font(Theme.uiTiny)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("Stage All") {
                            Task { await state.stageAll() }
                        }
                        .buttonStyle(.link)
                        .font(Theme.uiTiny)
                        .disabled(repo.unstagedChanges.isEmpty)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Rows

struct AllChangesRow: View {
    let selected: Bool
    let count: Int
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("All changes")
                    .font(Theme.ui)
                Spacer()
                Text("\(count)")
                    .font(Theme.uiTiny)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: Theme.rowHeight)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.14) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}

struct ChangeRow: View {
    let change: FileChange
    let selected: Bool
    let onSelect: () -> Void
    let onToggleStage: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggleStage) {
                Image(systemName: stageIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(change.staged ? Color.accentColor : Color.secondary.opacity(0.7))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(change.status == .conflict ? "Mark as resolved (git add)" : (change.staged ? "Unstage" : "Stage"))

            Text(change.status.badge)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.color(for: change.status))
                .frame(width: 10)

            Button(action: onSelect) {
                HStack(spacing: 5) {
                    Text(change.fileName)
                        .font(Theme.ui)
                        .lineLimit(1)
                    if !change.directory.isEmpty {
                        Text(change.directory)
                            .font(Theme.uiTiny)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    if change.isSensitive {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.color(for: .modified))
                            .help("Sensitive file: its diff is never sent to the agent")
                    }
                    Spacer(minLength: 4)
                    if change.status == .conflict {
                        Pill(text: "conflict", color: Theme.removed)
                    } else {
                        if change.additions > 0 {
                            Text("+\(change.additions)")
                                .font(Theme.uiTiny)
                                .foregroundStyle(Theme.added)
                        }
                        if change.deletions > 0 {
                            Text("\u{2212}\(change.deletions)")
                                .font(Theme.uiTiny)
                                .foregroundStyle(Theme.removed)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.rowHeight)
        .background(rowBackground)
        .onHover { hovering = $0 }
    }

    private var stageIcon: String {
        if change.status == .conflict { return "exclamationmark.triangle" }
        if change.staged && change.unstaged { return "minus.square" }
        return change.staged ? "checkmark.square.fill" : "square"
    }

    private var rowBackground: Color {
        if selected { return Color.accentColor.opacity(0.14) }
        if change.status == .conflict { return Theme.removed.opacity(0.08) }
        if hovering { return Color.primary.opacity(0.04) }
        return .clear
    }
}

// MARK: - Clean tree

struct CleanTreeView: View {
    let repo: RepoState

    var body: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.added)
            Text("No changes")
                .font(Theme.ui)
                .foregroundStyle(.secondary)
            if let last = repo.recentCommits.first {
                Text("Last commit: \(last.subject)")
                    .font(Theme.uiTiny)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.horizontal, 20)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
