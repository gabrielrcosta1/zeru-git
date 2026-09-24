import SwiftUI

/// Branch list with a filter. Local branches first, then the ones that exist
/// only on origin, which are checked out as a new tracking branch.
struct BranchPicker: View {
    @EnvironmentObject private var state: ProjectSession
    @State private var query = ""
    @State private var creating = false
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()

            if state.loadingBranches && state.branches.isEmpty {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                    Text("Reading branches\u{2026}")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 60)
            } else if filtered.isEmpty {
                Text(state.branches.isEmpty ? "No branches found." : "No branch matches \u{201c}\(query)\u{201d}.")
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
                    .frame(height: 60)
                    .padding(.horizontal, 12)
            } else {
                list
            }

            Hairline()
            newBranch

            if hiddenCount > 0 {
                Hairline()
                Text("\(hiddenCount) more branch\(hiddenCount == 1 ? "" : "es") \u{00b7} type to filter")
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let repo = state.repo, repo.hasChanges {
                Hairline()
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("\(repo.changes.count) uncommitted change\(repo.changes.count == 1 ? "" : "s") come with you. Git refuses the switch if a file would be overwritten.")
                        .font(Theme.micro)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 330)
        .task { await state.loadBranches() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            TextField("Filter branches", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.body)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            Button {
                Task {
                    await state.fetchRemote(silent: false)
                    await state.loadBranches()
                }
            } label: {
                if state.fetching {
                    ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(state.fetching || state.isBusy)
            .help("Fetch origin, then reload the list")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: New branch

    @ViewBuilder private var newBranch: some View {
        if creating {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                TextField("New branch name", text: $newName)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .onSubmit { create() }
                Button("Create") { create() }
                    .buttonStyle(.link)
                    .font(Theme.micro)
                    .disabled(trimmedName.isEmpty || state.isBusy)
                Button("Cancel") {
                    creating = false
                    newName = ""
                }
                .buttonStyle(.link)
                .font(Theme.micro)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        } else {
            Button {
                creating = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 13)
                    Text("New Branch")
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text("from \(state.repo?.branchLabel ?? "HEAD")")
                        .font(Theme.micro)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state.isBusy)
        }
    }

    private var trimmedName: String {
        return newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        let name = trimmedName
        guard !name.isEmpty, !state.isBusy else { return }
        creating = false
        newName = ""
        Task { await state.createBranch(named: name) }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if !locals.isEmpty {
                    sectionLabel("Local")
                    ForEach(locals) { branch in
                        BranchRow(branch: branch)
                    }
                }
                if !remotes.isEmpty {
                    sectionLabel("Remote")
                    ForEach(remotes) { branch in
                        BranchRow(branch: branch)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 330)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.sectionLabel)
            .kerning(0.8)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 7)
            .padding(.top, 6)
            .padding(.bottom, 3)
    }

    /// Everything that matches the filter.
    private var matches: [GitBranch] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return state.branches }
        return state.branches.filter { $0.name.lowercased().contains(needle) }
    }

    /// A repository can have a thousand refs. Show the most recent ones and let
    /// the filter reach the rest.
    private var limit: Int { return query.isEmpty ? 40 : 200 }

    private var filtered: [GitBranch] {
        let all = matches
        guard all.count > limit else { return all }
        var shown = Array(all.prefix(limit))
        if let current = state.branches.first(where: { $0.isCurrent }),
           !shown.contains(where: { $0.id == current.id }) {
            shown.insert(current, at: 0)
        }
        return shown
    }

    private var hiddenCount: Int { return max(0, matches.count - filtered.count) }

    private var locals: [GitBranch] { return filtered.filter { !$0.isRemote } }
    private var remotes: [GitBranch] { return filtered.filter { $0.isRemote } }
}

// MARK: - Row

struct BranchRow: View {
    let branch: GitBranch
    @EnvironmentObject private var state: ProjectSession
    @State private var hovering = false

    var body: some View {
        Button {
            Task { await state.switchTo(branch) }
        } label: {
            HStack(spacing: 7) {
                marker
                    .frame(width: 13)

                Text(branch.isRemote ? branch.localName : branch.name)
                    .font(Theme.body)
                    .foregroundStyle(branch.isCurrent ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let remote = branch.remote {
                    Text(remote)
                        .font(Theme.micro)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Theme.surface)
                        )
                }

                Spacer(minLength: 6)

                Text(branch.relativeDate)
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(background)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(branch.isCurrent || state.isBusy)
        .onHover { value in
            withAnimation(Theme.snap) { hovering = value }
        }
        .help(branch.isRemote ? "Check out as a new local branch tracking \(branch.name)" : branch.name)
    }

    @ViewBuilder private var marker: some View {
        if branch.isCurrent {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.accentColor)
        } else if branch.isRemote {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        } else {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private var background: Color {
        if branch.isCurrent { return Theme.surface }
        return hovering ? Theme.surfaceStrong : .clear
    }
}
