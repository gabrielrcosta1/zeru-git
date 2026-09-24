import SwiftUI

/// Only shown when more than one project is open. Scrolls, keeps the active tab
/// in view, and fades at the edge when there is more to the right.
struct TabBar: View {
    @EnvironmentObject private var workspace: Workspace

    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0

    private var overflowing: Bool { return contentWidth > viewportWidth + 1 }

    private var chipWidth: CGFloat { return workspace.tabs.count > 3 ? 124 : 152 }

    var body: some View {
        HStack(spacing: 2) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(workspace.tabs) { tab in
                            TabChip(tab: tab,
                                    active: tab.id == workspace.activeID,
                                    maxWidth: chipWidth)
                                .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(key: TabsContentWidth.self, value: geometry.size.width)
                        }
                    )
                }
                .onPreferenceChange(TabsContentWidth.self) { width in
                    contentWidth = width
                }
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(key: TabsViewportWidth.self, value: geometry.size.width)
                    }
                )
                .onPreferenceChange(TabsViewportWidth.self) { width in
                    viewportWidth = width
                }
                .overlay(alignment: .trailing) { edgeFade }
                .onChange(of: workspace.activeID) { id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .onAppear {
                    guard let id = workspace.activeID else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }

            if workspace.tabs.count > 2 || overflowing {
                overflowMenu
                    .padding(.trailing, 8)
            }
        }
        .padding(.bottom, 7)
    }

    /// Says "there is more" without putting a scrollbar in the chrome.
    @ViewBuilder private var edgeFade: some View {
        if overflowing {
            LinearGradient(colors: [Color(nsColor: .windowBackgroundColor).opacity(0),
                                    Color(nsColor: .windowBackgroundColor)],
                           startPoint: .leading,
                           endPoint: .trailing)
                .frame(width: 22)
                .allowsHitTesting(false)
        }
    }

    /// Every open project, reachable even when its tab is scrolled out of sight.
    private var overflowMenu: some View {
        Menu {
            ForEach(workspace.tabs) { tab in
                Button {
                    workspace.select(tab)
                } label: {
                    if tab.id == workspace.activeID {
                        Label(tab.projectName, systemImage: "checkmark")
                    } else {
                        Text(tab.projectName)
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("All open projects (\u{2318}\u{21e7}[ and \u{2318}\u{21e7}])")
    }
}

private struct TabsContentWidth: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TabsViewportWidth: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct TabChip: View {
    @ObservedObject var tab: ProjectSession
    let active: Bool
    var maxWidth: CGFloat = 152

    @EnvironmentObject private var workspace: Workspace
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                workspace.select(tab)
            } label: {
                HStack(spacing: 6) {
                    marker
                    Text(tab.projectName)
                        .font(.system(size: 11.5, weight: active ? .medium : .regular))
                        .foregroundStyle(active ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    trailing
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 8)
        .padding(.trailing, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: maxWidth)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(active ? Theme.surfaceStrong : (hovering ? Theme.surface : Color.clear))
        )
        .overlay(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.accentColor)
                .frame(height: 1.5)
                .padding(.horizontal, 6)
                .opacity(active ? 0.8 : 0)
                .allowsHitTesting(false)
        }
        .onHover { value in
            withAnimation(Theme.snap) { hovering = value }
        }
        .help(tab.root.path)
    }

    /// A dot only when the project needs attention.
    @ViewBuilder private var marker: some View {
        if tab.repo?.hasConflicts == true {
            Circle()
                .fill(Theme.bad)
                .frame(width: 5, height: 5)
        } else if let repo = tab.repo, repo.ahead > 0 {
            Circle()
                .fill(Color.accentColor.opacity(0.8))
                .frame(width: 5, height: 5)
        } else {
            ProjectDot(name: tab.projectName)
        }
    }

    /// The change count, replaced by the close button on hover.
    private var trailing: some View {
        ZStack(alignment: .trailing) {
            if let repo = tab.repo, repo.hasChanges {
                Text("\(repo.changes.count)")
                    .font(Theme.micro)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 0 : 1)
            }
            Button {
                workspace.close(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .help("Close this project")
        }
        .frame(width: 16, alignment: .trailing)
    }
}

/// The project initial, small enough to sit in a tab.
struct ProjectDot: View {
    let name: String

    var body: some View {
        Text(initial)
            .font(.system(size: 8, weight: .semibold, design: .rounded))
            .foregroundStyle(.tertiary)
            .frame(width: 12, height: 12)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Theme.surfaceStrong)
            )
    }

    private var initial: String {
        guard let first = name.trimmingCharacters(in: .whitespacesAndNewlines).first else { return "?" }
        return String(first).uppercased()
    }
}
