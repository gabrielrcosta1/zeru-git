import AppKit
import SwiftUI

struct ChangesSection: View {
    @EnvironmentObject private var state: ProjectSession
    @State private var hoveringSelectAll = false

    var body: some View {
        if let repo = state.repo, !repo.hasChanges {
            VStack(alignment: .leading, spacing: 3) {
                Text("No changes")
                    .font(Theme.bodyEmphasis)
                    .foregroundStyle(.secondary)
                if let last = repo.recentCommits.first {
                    HStack(spacing: 5) {
                        Image(systemName: "smallcircle.filled.circle")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text("\(last.subject) \u{00b7} \(last.relativeDate)")
                            .font(Theme.micro)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let repo = state.repo {
            VStack(alignment: .leading, spacing: 3) {
                header(repo)
                VStack(spacing: 1) {
                    ForEach(repo.changes) { change in
                        ChangeRow(change: change, selected: state.selectedPath == change.path)
                    }
                }
            }
        }
    }

    // MARK: Header

    private func header(_ repo: RepoState) -> some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    guard let current = state.repo else { return }
                    if selectionState(current) == .on {
                        await state.deselectAll()
                    } else {
                        await state.stageAll()
                    }
                }
            } label: {
                Checkbox(state: selectionState(repo), hovering: hoveringSelectAll)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { value in
                withAnimation(Theme.snap) { hoveringSelectAll = value }
            }
            .help(selectionState(repo) == .on ? "Deselect all" : "Select all")

            Text("CHANGES")
                .font(Theme.sectionLabel)
                .kerning(0.8)
                .foregroundStyle(.tertiary)

            Spacer(minLength: 4)

            Text(selectionLabel(repo))
                .font(Theme.micro)
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            Menu {
                Button("Select All") { Task { await state.stageAll() } }
                Button("Deselect All") { Task { await state.deselectAll() } }
                Divider()
                Button("Discard Selected\u{2026}") { state.requestDiscardSelected() }
                    .disabled(repo.stagedChanges.isEmpty)
                Button("Discard All Changes\u{2026}") { state.requestDiscardAll() }
                Divider()
                Button("Stash Changes") { Task { await state.stashChanges() } }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(state.isBusy)
            .help("Selection and discard")
        }
        .padding(.leading, 7)
        .padding(.trailing, 6)
        .padding(.bottom, 3)
    }

    private func selectionState(_ repo: RepoState) -> CheckboxState {
        let selectable = repo.changes.filter { $0.status != .conflict }
        guard !selectable.isEmpty else { return .off }
        let selected = selectable.filter { $0.staged }
        if selected.isEmpty { return .off }
        if selected.count == selectable.count && selected.allSatisfy({ !$0.unstaged }) { return .on }
        return .mixed
    }

    private func selectionLabel(_ repo: RepoState) -> String {
        let selectable = repo.changes.filter { $0.status != .conflict }
        let selected = selectable.filter { $0.staged }.count
        if selected == 0 { return "\(selectable.count) files" }
        return "\(selected) of \(selectable.count) selected"
    }
}

// MARK: - Row

struct ChangeRow: View {
    let change: FileChange
    let selected: Bool

    @EnvironmentObject private var state: ProjectSession
    @State private var hovering = false

    private var expanded: Bool { return state.inlinePath == change.path }

    var body: some View {
        VStack(spacing: 0) {
            row
            if expanded {
                InlineDiff()
            }
        }
        .animation(Theme.ease, value: expanded)
    }

    private var row: some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    guard let current = state.repo?.changes.first(where: { $0.path == change.path }) else { return }
                    if current.status == .conflict {
                        await state.markResolved(current)
                    } else {
                        await state.toggleStage(current)
                    }
                }
            } label: {
                checkbox
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(change.staged || hovering ? 1 : 0.45)
            .help(helpText)

            StatusIcon(status: change.status)

            Button {
                Task {
                    guard let current = state.repo?.changes.first(where: { $0.path == change.path }) else { return }
                    await state.toggleInline(current)
                }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(change.fileName)
                            .font(Theme.body)
                            .foregroundStyle(change.status == .deleted ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if change.isSensitive {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(Theme.warn)
                                .help("Sensitive file: its contents are never sent to the agent")
                        }
                    }
                    Text(change.directory.isEmpty ? "repository root" : change.directory)
                        .font(Theme.micro)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide the diff" : "Show the diff here")

            trailing

            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .opacity(hovering || expanded ? 0.9 : 0.3)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
        }
        .padding(.leading, 7)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(rowFill)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: 2, height: 18)
                .opacity(selected || expanded ? 0.75 : 0)
                .allowsHitTesting(false)
        }
        .onHover { value in
            withAnimation(Theme.snap) { hovering = value }
        }
        .contextMenu {
            Button(expanded ? "Hide Diff" : "Show Diff") {
                Task { await state.toggleInline(change) }
            }
            Button("Open in Side Panel") { Task { await state.open(change: change) } }
            Button("Open File") { state.revealInEditor(change) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(change.path, forType: .string)
            }
            Divider()
            if change.status == .untracked {
                Button("Ignore \(ProjectSession.ignorePattern(for: change.path))") {
                    Task { await state.ignore(change) }
                }
            }
            Button(change.status == .untracked || change.status == .added
                   ? "Move to Trash\u{2026}" : "Discard Changes\u{2026}") {
                state.requestDiscard(change)
            }
        }
    }

    // MARK: Pieces

    @ViewBuilder private var checkbox: some View {
        if change.status == .conflict {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.bad)
                .frame(width: 13, height: 13)
        } else {
            Checkbox(state: change.staged ? (change.unstaged ? .mixed : .on) : .off,
                     hovering: hovering)
        }
    }

    /// Counts and hover actions share the same slot, so nothing reflows.
    private var trailing: some View {
        ZStack(alignment: .trailing) {
            if change.status == .conflict {
                Text("conflict")
                    .font(Theme.micro)
                    .foregroundStyle(Theme.bad)
                    .opacity(hovering ? 0 : 1)
            } else {
                DiffCounts(additions: change.additions, deletions: change.deletions)
                    .opacity(hovering ? 0 : 1)
            }

            HStack(spacing: 1) {
                QuickAction(icon: "arrow.up.left.and.arrow.down.right",
                            help: "Open in the side panel") {
                    Task { await state.open(change: change) }
                }
                QuickAction(icon: "arrow.up.forward.app", help: "Open file") {
                    state.revealInEditor(change)
                }
                QuickAction(icon: "arrow.uturn.backward",
                            help: change.status == .untracked ? "Move file to Trash" : "Discard changes",
                            destructive: true) {
                    state.requestDiscard(change)
                }
            }
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .frame(width: 76, alignment: .trailing)
    }

    private var helpText: String {
        if change.status == .conflict { return "Mark as resolved" }
        return change.staged ? "Remove from this commit" : "Include in this commit"
    }

    private var rowFill: Color {
        if selected || expanded { return Theme.surfaceStrong }
        if change.status == .conflict { return Theme.bad.opacity(0.07) }
        if hovering { return Theme.surface }
        return .clear
    }
}


// MARK: - Inline diff

/// The diff of the expanded file, right under it. No navigation, no lost context.
struct InlineDiff: View {
    @EnvironmentObject private var state: ProjectSession

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .padding(.leading, 22)
            .padding(.top, 3)
            .padding(.bottom, 5)
            .transition(.opacity)
    }

    @ViewBuilder private var content: some View {
        if state.loadingInline && state.inlineDiff == nil {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 12, height: 12)
                Text("Reading the diff\u{2026}")
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
        } else if let diff = state.inlineDiff, diff.isBinary {
            note("Binary file")
        } else if let diff = state.inlineDiff, !diff.hunks.isEmpty {
            VStack(spacing: 0) {
                DiffBody(diff: diff)
                    .frame(maxHeight: 260)
                footer(diff)
            }
        } else {
            note("Nothing to show for this file")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.micro)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .frame(height: 40)
    }

    private func footer(_ diff: FileDiff) -> some View {
        HStack(spacing: 8) {
            DiffCounts(additions: diff.additions, deletions: diff.deletions)
            Spacer(minLength: 4)
            Button("Open in panel") {
                if let path = state.inlinePath,
                   let change = state.repo?.changes.first(where: { $0.path == path }) {
                    Task { await state.open(change: change) }
                }
            }
            .buttonStyle(.link)
            .font(Theme.micro)
            Button("Close") {
                if let path = state.inlinePath,
                   let change = state.repo?.changes.first(where: { $0.path == path }) {
                    Task { await state.toggleInline(change) }
                }
            }
            .buttonStyle(.link)
            .font(Theme.micro)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Theme.surface)
    }
}
