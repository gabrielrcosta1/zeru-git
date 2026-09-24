import SwiftUI

enum Theme {
    static let corner: CGFloat = 8
    static let rowHeight: CGFloat = 26

    static let ui = Font.system(size: 12)
    static let uiSmall = Font.system(size: 11)
    static let uiTiny = Font.system(size: 10)
    static let uiBold = Font.system(size: 12, weight: .semibold)
    static let title = Font.system(size: 13, weight: .semibold)
    static let code = Font.system(size: 11, design: .monospaced)
    static let codeNumber = Font.system(size: 10, design: .monospaced)

    static let added = Color(red: 0.16, green: 0.62, blue: 0.36)
    static let removed = Color(red: 0.80, green: 0.25, blue: 0.25)
    static let addedBackground = Color(red: 0.16, green: 0.62, blue: 0.36).opacity(0.12)
    static let removedBackground = Color(red: 0.80, green: 0.25, blue: 0.25).opacity(0.12)
    static let accent = Color.accentColor

    static func color(for status: FileStatus) -> Color {
        switch status {
        case .modified: return Color(red: 0.85, green: 0.60, blue: 0.15)
        case .added: return added
        case .deleted: return removed
        case .renamed: return Color(red: 0.30, green: 0.50, blue: 0.85)
        case .copied: return Color(red: 0.30, green: 0.50, blue: 0.85)
        case .typeChanged: return Color(red: 0.55, green: 0.40, blue: 0.75)
        case .untracked: return Color.secondary
        case .conflict: return removed
        }
    }

    static func color(for risk: RiskLevel) -> Color {
        switch risk {
        case .low: return added
        case .medium: return Color(red: 0.85, green: 0.60, blue: 0.15)
        case .high: return removed
        case .unknown: return Color.secondary
        }
    }

    static func color(for kind: ActivityKind) -> Color {
        switch kind {
        case .info: return .secondary
        case .tool: return Color(red: 0.30, green: 0.50, blue: 0.85)
        case .agent: return .accentColor
        case .warning: return Color(red: 0.85, green: 0.60, blue: 0.15)
        case .success: return added
        case .failure: return removed
        }
    }

    static func icon(for kind: ActivityKind) -> String {
        switch kind {
        case .info: return "circle.fill"
        case .tool: return "wrench.and.screwdriver"
        case .agent: return Theme.aiMark
        case .warning: return "exclamationmark.triangle"
        case .success: return "checkmark"
        case .failure: return "xmark"
        }
    }

    static func color(for operation: GitOperation) -> Color {
        switch operation {
        case .commit, .push, .branchCreate, .conflictResolve:
            return ok
        case .pull, .fetch, .checkout, .stashBranch:
            return Color(red: 0.30, green: 0.50, blue: 0.85)
        case .stash, .stashApply, .stashPop:
            return .secondary
        case .stashDrop, .discard, .rebaseAbort:
            return warn
        case .aiFix:
            return .accentColor
        case .recoverBranch, .recoverReset:
            return ok
        case .rebase:
            return Color(red: 0.55, green: 0.40, blue: 0.75)
        case .aiCommand:
            return .accentColor
        case .workflow:
            return Color(red: 0.30, green: 0.50, blue: 0.85)
        }
    }

    static func icon(for operation: GitOperation) -> String {
        switch operation {
        case .commit: return "checkmark.circle"
        case .push: return "arrow.up"
        case .pull: return "arrow.down"
        case .fetch: return "arrow.down.circle"
        case .checkout: return "arrow.triangle.branch"
        case .branchCreate: return "plus.circle"
        case .stash: return "tray.and.arrow.down"
        case .stashApply, .stashPop: return "tray.and.arrow.up"
        case .stashDrop: return "trash"
        case .stashBranch: return "arrow.triangle.branch"
        case .discard: return "arrow.uturn.backward"
        case .rebaseAbort: return "xmark.circle"
        case .conflictResolve: return "arrow.triangle.merge"
        case .aiFix: return Theme.aiMark
        case .recoverBranch, .recoverReset: return "arrow.counterclockwise"
        case .rebase: return "arrow.triangle.merge"
        case .aiCommand: return "terminal"
        case .workflow: return "square.stack.3d.up"
        }
    }

    static func color(for risk: GitCommandRisk) -> Color {
        switch risk {
        case .read: return .secondary
        case .safe: return ok
        case .destructive: return warn
        case .refused: return bad
        }
    }

    static func icon(for risk: GitCommandRisk) -> String {
        switch risk {
        case .read: return "eye"
        case .safe: return "checkmark"
        case .destructive: return "exclamationmark.triangle.fill"
        case .refused: return "nosign"
        }
    }

    static func color(for state: WorkflowStepState) -> Color {
        switch state {
        case .pending: return Color.secondary.opacity(0.5)
        case .running: return .accentColor
        case .done: return ok
        case .failed: return bad
        case .skipped: return Color.secondary.opacity(0.5)
        }
    }

    static func icon(for state: WorkflowStepState) -> String {
        switch state {
        case .pending: return "circle"
        case .running: return "circle.fill"
        case .done: return "checkmark"
        case .failed: return "xmark"
        case .skipped: return "minus"
        }
    }

    static func icon(for hit: SearchHit) -> String {
        switch hit {
        case .command(let command):
            switch command {
            case .checkout: return "arrow.triangle.branch"
            case .createBranch: return "plus.circle"
            case .stash: return "tray.and.arrow.down"
            case .popStash: return "tray.and.arrow.up"
            case .fetch: return "arrow.down.circle"
            case .pull: return "arrow.down"
            case .push: return "arrow.up"
            case .review, .generateMessage: return Theme.aiMark
            case .refresh: return "arrow.clockwise"
            case .abortRebase: return "xmark.circle"
            case .showChanges: return "plus.forwardslash.minus"
            case .showActivity: return "clock"
            case .showStashes: return "tray"
            case .showRecovery: return "arrow.counterclockwise"
            case .showRebase: return "arrow.triangle.merge"
            case .showForge: return "arrow.triangle.pull"
            case .showWorkflows, .createWorkflow: return "square.stack.3d.up"
            case .askAgent: return Theme.aiMark
            case .syncPull: return "arrow.triangle.2.circlepath"
            case .openOnWeb: return "globe"
            }
        case .branch(let branch):
            return branch.isRemote ? "arrow.down.circle" : "arrow.triangle.branch"
        case .commit:
            return "checkmark.circle"
        case .file:
            return "doc"
        case .workflow:
            return "square.stack.3d.up"
        }
    }

    // MARK: - Redesign tokens

    static let projectTitle = Font.system(size: 15, weight: .semibold)
    static let sectionLabel = Font.system(size: 9.5, weight: .semibold)
    static let bigNumber = Font.system(size: 19, weight: .light)
    static let body = Font.system(size: 12)
    static let bodyEmphasis = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 10.5)
    static let micro = Font.system(size: 9.5)
    static let mono = Font.system(size: 10.5, design: .monospaced)
    static let numeric = Font.system(size: 10, weight: .medium, design: .monospaced)

    /// One mark stands for "the agent did this". Not a star, not an emoji.
    static let aiMark = "asterisk"

    // Motion: short, flat, never bouncy.
    static let snap = Animation.easeOut(duration: 0.12)
    static let ease = Animation.easeInOut(duration: 0.18)

    /// Barely there separators: one hairline, never a box.
    static var hairline: Color { return Color.primary.opacity(0.075) }
    /// Raised surface for the one block that deserves emphasis.
    static var surface: Color { return Color.primary.opacity(0.035) }
    static var surfaceStrong: Color { return Color.primary.opacity(0.07) }

    /// Brand, used for identity only (the mark, the icon). State keeps its own
    /// colours so orange never means "attention".
    static let brand = Color(red: 1.0, green: 0.49, blue: 0.10)
    static let brandLight = Color(red: 1.0, green: 0.68, blue: 0.24)

    static let ok = Color(red: 0.33, green: 0.72, blue: 0.45)
    static let warn = Color(red: 0.92, green: 0.70, blue: 0.28)
    static let bad = Color(red: 0.91, green: 0.40, blue: 0.38)

    static func tint(for risk: RiskLevel) -> Color {
        switch risk {
        case .low: return ok
        case .medium: return warn
        case .high: return bad
        case .unknown: return Color.secondary
        }
    }
}

/// Uppercase section label. The only structural type in the compact column.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title.uppercased())
                .font(Theme.sectionLabel)
                .kerning(0.8)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.title = title
        self.trailing = EmptyView()
    }
}

/// One hairline, edge to edge.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
    }
}

/// Icon of a change kind. Monochrome except for deletions and conflicts.
struct StatusIcon: View {
    let status: FileStatus

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 13, height: 13)
            .help(status.label)
    }

    private var symbol: String {
        switch status {
        case .modified: return "pencil"
        case .added: return "plus"
        case .deleted: return "minus"
        case .renamed: return "arrow.right"
        case .copied: return "doc.on.doc"
        case .typeChanged: return "arrow.left.arrow.right"
        case .untracked: return "circle.dashed"
        case .conflict: return "exclamationmark.triangle.fill"
        }
    }

    private var size: CGFloat {
        switch status {
        case .conflict: return 9.5
        case .untracked: return 9
        case .copied: return 8.5
        default: return 10
        }
    }

    private var tint: Color {
        switch status {
        case .conflict: return Theme.bad
        case .deleted: return Theme.removed.opacity(0.9)
        case .added: return Theme.added.opacity(0.9)
        default: return Color.secondary
        }
    }
}

/// Checkbox that also carries a mixed state, aligned on a 13pt box.
enum CheckboxState {
    case off
    case on
    case mixed
}

struct Checkbox: View {
    let state: CheckboxState
    var tint: Color = .accentColor
    var hovering: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(state == .off ? Color.clear : tint)
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .strokeBorder(state == .off
                              ? Color.primary.opacity(hovering ? 0.42 : 0.26)
                              : Color.clear,
                              lineWidth: 1)
            if state == .on {
                Image(systemName: "checkmark")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(Color.white)
            } else if state == .mixed {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 6, height: 1.5)
            }
        }
        .frame(width: 13, height: 13)
        .animation(Theme.snap, value: state)
    }
}

/// Icon-only action that only becomes visible on row hover.
struct QuickAction: View {
    let icon: String
    let help: String
    var destructive = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 19, height: 19)
                .background(
                    Circle().fill(hovering ? Theme.surfaceStrong : Color.clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { value in
            withAnimation(Theme.snap) { hovering = value }
        }
        .help(help)
    }

    private var foreground: Color {
        if destructive { return hovering ? Theme.bad : Color.secondary }
        return hovering ? Color.primary : Color.secondary
    }
}

/// The branch, unmistakably a branch.
struct BranchChip: View {
    let name: String
    var sync: String?
    var interactive = false
    var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(name)
                .font(Theme.caption)
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
            if let sync {
                Text(sync)
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            if interactive {
                Image(systemName: "chevron.down")
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hovering ? Theme.surfaceStrong : Theme.surface)
        )
    }
}

/// Project mark: the repository initial, not an emoji.
struct ProjectMark: View {
    let name: String

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Theme.surfaceStrong)
            .frame(width: 20, height: 20)
            .overlay(
                Text(initial)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            )
    }

    private var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }
}

/// Discreet added/removed counters, optionally in a capsule with a diff mark.
struct DiffCounts: View {
    let additions: Int
    let deletions: Int
    var boxed = false
    var showsIcon = false

    var body: some View {
        HStack(spacing: 5) {
            if showsIcon {
                Image(systemName: "plus.forwardslash.minus")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            if additions > 0 {
                Text("+\(additions)")
                    .foregroundStyle(Theme.added)
            }
            if deletions > 0 {
                Text("\u{2212}\(deletions)")
                    .foregroundStyle(Theme.removed)
            }
            if additions == 0 && deletions == 0 {
                Text("\u{2013}")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(Theme.numeric)
        .monospacedDigit()
        .padding(.horizontal, boxed ? 7 : 0)
        .padding(.vertical, boxed ? 3 : 0)
        .background(
            Capsule(style: .continuous)
                .fill(boxed ? Theme.surface : Color.clear)
        )
    }
}

/// Small pill used for statuses and counters.
struct Pill: View {
    let text: String
    let color: Color
    var filled = false

    var body: some View {
        Text(text)
            .font(Theme.uiTiny)
            .fontWeight(.medium)
            .foregroundStyle(filled ? Color.white : color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(filled ? color : color.opacity(0.14))
            )
    }
}

/// Section label in the sidebar style of professional macOS apps.
struct SectionLabel: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(Theme.uiTiny)
                .fontWeight(.semibold)
                .foregroundStyle(.tertiary)
                .kerning(0.6)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(Theme.uiTiny)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

// MARK: - Buttons

/// The one button in the product. Prominent for the action the user came for,
/// quiet for everything next to it.
struct ActionButton: View {
    let title: String
    var icon: String?
    var prominent = false
    var busy = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                        .frame(width: 10, height: 10)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9.5, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { value in
            guard isEnabled else { return }
            withAnimation(Theme.snap) { hovering = value }
        }
    }

    private var foreground: Color {
        if prominent { return .white }
        return hovering ? .primary : .primary.opacity(0.85)
    }

    private var fill: Color {
        if prominent {
            return hovering ? Color.accentColor.opacity(0.88) : Color.accentColor
        }
        return hovering ? Theme.surfaceStrong : Theme.surface
    }

    private var stroke: Color {
        if prominent { return .clear }
        return Theme.hairline
    }
}

/// Slow, quiet pulse for the step the agent is on.
struct PulsingDot: View {
    var color: Color = .accentColor
    @State private var bright = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .opacity(bright ? 1 : 0.3)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    bright = true
                }
            }
    }
}
