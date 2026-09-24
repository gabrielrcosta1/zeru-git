import SwiftUI

/// One field over the window. Branches, files and commands answer as you type;
/// commits are asked of git once typing pauses.
struct CommandPalette: View {
    @ObservedObject var session: ProjectSession
    @EnvironmentObject private var workspace: Workspace

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var hits: [SearchHit] { return session.searchResults }

    var body: some View {
        ZStack(alignment: .top) {
            // Anywhere outside closes it.
            Rectangle()
                .fill(Color.black.opacity(0.3))
                .onTapGesture { close() }

            panel
                .frame(maxWidth: 560)
                .padding(.horizontal, 14)
                .padding(.top, 52)

            keys
        }
        .ignoresSafeArea()
        .onAppear {
            focused = true
            Task {
                await session.prepareSearch()
                session.updateSearch(query)
            }
        }
        .onDisappear { session.endSearch() }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            field

            if !hits.isEmpty {
                Hairline()
                list
            } else if session.searching {
                Hairline()
                message("Searching\u{2026}")
            } else if SearchQuery(query).isBareScope {
                Hairline()
                message(prompt)
            } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Hairline()
                message("Nothing matches \u{201c}\(query)\u{201d}.")
            }

            Hairline()
            hintBar
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: Color.black.opacity(0.32), radius: 22, y: 8)
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)

            TextField("Search commits, branches and files \u{2014} or \u{203a} for commands",
                      text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($focused)
                .onSubmit { activate() }
                .onChange(of: query) { value in
                    selection = 0
                    session.updateSearch(value)
                }

            if session.searching {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .frame(width: 12, height: 12)
            }

            Button {
                close()
            } label: {
                Text("esc")
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Theme.surface)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
    }

    // MARK: Results

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { pair in
                        if pair.offset == 0 || hits[pair.offset - 1].group != pair.element.group {
                            Text(pair.element.group.uppercased())
                                .font(Theme.sectionLabel)
                                .kerning(0.8)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.top, pair.offset == 0 ? 4 : 9)
                                .padding(.bottom, 3)
                        }
                        PaletteRow(hit: pair.element, selected: pair.offset == selection)
                            .id(pair.element.id)
                            .onTapGesture {
                                selection = pair.offset
                                activate()
                            }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 330)
            .onChange(of: selection) { value in
                guard hits.indices.contains(value) else { return }
                proxy.scrollTo(hits[value].id, anchor: .center)
            }
        }
    }

    /// What a scope with nothing typed after it is waiting for.
    private var prompt: String {
        switch SearchQuery(query).scope {
        case .commits: return "Type what the commit message says."
        case .branches: return "Type part of a branch name."
        case .files: return "Type part of a file name or path."
        case .author: return "Type an author's name or email."
        case .commands, .all: return "Type a command."
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hintBar: some View {
        HStack(spacing: 10) {
            hint("\u{2191}\u{2193}", "move")
            hint("\u{21a9}", "open")
            hint("\u{203a}", "commands")
            hint("branch:", "narrow")
            Spacer(minLength: 0)
            if let repo = session.repo {
                Text(repo.branchLabel)
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(Theme.micro)
                .foregroundStyle(.secondary)
            Text(label)
                .font(Theme.micro)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Keys

    /// Zero-sized buttons, so the arrow keys and return work while the field
    /// has focus. They stay in the hierarchy on purpose: a hidden view does not
    /// always keep its shortcut.
    private var keys: some View {
        VStack(spacing: 0) {
            Button("") { move(-1) }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("") { move(1) }
                .keyboardShortcut(.downArrow, modifiers: [])
            Button("") { close() }
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: Actions

    private func move(_ offset: Int) {
        guard !hits.isEmpty else { return }
        let next = selection + offset
        selection = min(max(next, 0), hits.count - 1)
    }

    private func activate() {
        guard hits.indices.contains(selection) else { return }
        let hit = hits[selection]
        Task { await session.activate(hit) }
    }

    private func close() {
        workspace.paletteOpen = false
        session.endSearch()
    }
}

// MARK: - Row

struct PaletteRow: View {
    let hit: SearchHit
    let selected: Bool

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: Theme.icon(for: hit))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .frame(width: 15)

            VStack(alignment: .leading, spacing: 1) {
                Text(hit.title)
                    .font(Theme.body)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = hit.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.micro)
                        .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 6)

            if let trailing = hit.trailing {
                Text(trailing)
                    .font(Theme.micro)
                    .foregroundStyle(selected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(background)
        )
        .contentShape(Rectangle())
        .onHover { value in
            hovering = value
        }
    }

    private var background: Color {
        if selected { return Color.accentColor }
        return hovering ? Theme.surface : .clear
    }
}
