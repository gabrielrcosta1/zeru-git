import SwiftUI

/// Every stash in the repository, with its diff one click away so nothing is
/// ever applied blind. Apply keeps the entry, pop removes it, drop asks first.
struct StashPanel: View {
    @EnvironmentObject private var state: ProjectSession

    @State private var naming = false
    @State private var branchName = ""

    var body: some View {
        VStack(spacing: 0) {
            if !state.stashesLoaded && state.stashes.isEmpty {
                reading
            } else if state.stashes.isEmpty && state.stashReadFailed {
                unreadable
            } else if state.stashes.isEmpty {
                empty
            } else {
                list
            }

            if let entry = selected {
                Hairline()
                actions(for: entry)
                Hairline()
                DiffView(diff: state.stashDiff, loading: state.loadingStashDiff)
            } else if !state.stashes.isEmpty {
                Hairline()
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: state.expandedStash) { _ in
            naming = false
            branchName = ""
        }
    }

    private var selected: GitStashEntry? {
        guard let sha = state.expandedStash else { return nil }
        return state.stashes.first { $0.sha == sha }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(state.stashes) { entry in
                    StashRow(entry: entry)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: selected == nil ? .infinity : 210)
    }

    // MARK: Reading

    private var reading: some View {
        VStack(spacing: 8) {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text("Reading the stash list\u{2026}")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unreadable: some View {
        VStack(spacing: 9) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(Theme.warn)
            Text("Could not read the stash list.")
                .font(Theme.body)
                .foregroundStyle(.secondary)
            ActionButton(title: "Try Again", icon: "arrow.clockwise") {
                Task { await state.refreshStash() }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    // MARK: Empty

    private var empty: some View {
        VStack(spacing: 9) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing is stashed.")
                .font(Theme.body)
                .foregroundStyle(.secondary)
            Text("A stash parks the working tree without committing it. Nothing is lost: apply or pop brings it all back.")
                .font(Theme.micro)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
            if state.repo?.hasChanges == true {
                ActionButton(title: stashTitle, icon: "tray.and.arrow.down") {
                    Task { await state.stashChanges() }
                }
                .disabled(state.isBusy)
                .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if state.repo?.hasChanges == true {
                ActionButton(title: stashTitle, icon: "tray.and.arrow.down") {
                    Task { await state.stashChanges() }
                }
                .disabled(state.isBusy)
            } else {
                Text("Select a stash to see what it would apply.")
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var stashTitle: String {
        let count = state.repo?.changes.count ?? 0
        return count == 1 ? "Stash 1 change" : "Stash \(count) changes"
    }

    // MARK: Actions

    @ViewBuilder private func actions(for entry: GitStashEntry) -> some View {
        if naming {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                TextField("New branch name", text: $branchName)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .onSubmit { branchOff(entry) }
                Button("Create Branch") { branchOff(entry) }
                    .buttonStyle(.link)
                    .font(Theme.micro)
                    .disabled(trimmedBranchName.isEmpty || state.isBusy)
                Button("Cancel") {
                    naming = false
                    branchName = ""
                }
                .buttonStyle(.link)
                .font(Theme.micro)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        } else {
            HStack(spacing: 8) {
                ActionButton(title: "Apply", icon: "arrow.down", prominent: true) {
                    Task { await state.applyStash(entry, thenDrop: false) }
                }
                .disabled(state.isBusy)
                .help("Apply these changes and keep the stash")

                ActionButton(title: "Pop", icon: "arrow.down.to.line") {
                    Task { await state.applyStash(entry, thenDrop: true) }
                }
                .disabled(state.isBusy)
                .help("Apply these changes and remove the stash")

                ActionButton(title: "Branch\u{2026}", icon: "arrow.triangle.branch") {
                    branchName = entry.suggestedBranchName
                    naming = true
                }
                .disabled(state.isBusy)
                .help("Create a branch at the commit this stash was made on and apply it there")

                Spacer(minLength: 0)

                Text(entry.shortSha)
                    .font(Theme.mono)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .help("The stash commit. It stays reachable by this sha even after a drop.")

                QuickAction(icon: "trash", help: "Drop this stash", destructive: true) {
                    state.requestStashDrop(entry)
                }
                .disabled(state.isBusy)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }

    private var trimmedBranchName: String {
        return branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func branchOff(_ entry: GitStashEntry) {
        let name = trimmedBranchName
        guard !name.isEmpty, !state.isBusy else { return }
        naming = false
        branchName = ""
        Task { await state.branchFromStash(entry, named: name) }
    }
}

// MARK: - Row

struct StashRow: View {
    let entry: GitStashEntry
    @EnvironmentObject private var state: ProjectSession
    @State private var hovering = false

    private var isOpen: Bool { return state.expandedStash == entry.sha }

    var body: some View {
        Button {
            Task { await state.toggleStash(entry) }
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(entry.ref)
                            .font(Theme.mono)
                            .foregroundStyle(.tertiary)
                        Text(entry.title)
                            .font(Theme.bodyEmphasis)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack(spacing: 6) {
                        Text(entry.when)
                            .font(Theme.micro)
                            .foregroundStyle(.tertiary)
                        if let branch = entry.branch {
                            Text("\u{00b7}")
                                .font(Theme.micro)
                                .foregroundStyle(.tertiary)
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 7.5))
                                Text(branch)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .font(Theme.micro)
                            .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer(minLength: 6)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(background)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { value in
            withAnimation(Theme.snap) { hovering = value }
        }
    }

    private var background: Color {
        if isOpen { return Theme.surfaceStrong }
        return hovering ? Theme.surface : .clear
    }
}
