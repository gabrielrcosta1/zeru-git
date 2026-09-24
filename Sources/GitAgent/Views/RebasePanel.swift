import SwiftUI

/// The sequence of commits that can still be rewritten, as a plan you edit
/// before anything happens. Drag to reorder, or use the arrows.
///
/// Only commits the upstream does not have appear here: rewriting a published
/// commit needs a force push, and this app does not force push.
struct RebasePanel: View {
    @EnvironmentObject private var state: ProjectSession

    var body: some View {
        VStack(spacing: 0) {
            content
            if state.rebasePlan != nil {
                Hairline()
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var content: some View {
        if state.loadingRebase && state.rebasePlan == nil {
            VStack(spacing: 8) {
                Spacer()
                ProgressView().controlSize(.small)
                Text("Reading the commits\u{2026}")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let note = state.rebaseNote {
            VStack(spacing: 9) {
                Spacer()
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(note)
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)
        } else if let plan = state.rebasePlan {
            list(plan)
        } else {
            PanelPlaceholder(text: "Nothing to reorganize.")
        }
    }

    /// A List, because dragging rows is what List does natively on macOS. The
    /// arrows next to each row do the same thing for anyone who would rather
    /// click than drag.
    private func list(_ plan: RebasePlan) -> some View {
        List {
            Section {
                ForEach(Array(plan.steps.enumerated()), id: \.element.id) { pair in
                    RebaseRow(index: pair.offset,
                              step: pair.element,
                              count: plan.steps.count)
                        .listRowInsets(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
                        .listRowSeparator(.hidden)
                }
                .onMove { source, destination in
                    state.moveRebaseSteps(from: source, to: destination)
                }
            } header: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("OLDEST FIRST \u{00b7} REPLAYED ONTO \(plan.base.label.uppercased())")
                        .font(Theme.sectionLabel)
                        .kerning(0.8)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if plan.truncated {
                        Text("Only the \(plan.steps.count) most recent are shown. Older ones stay exactly as they are.")
                            .font(Theme.micro)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem = state.rebaseProblem {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.bad)
                        .padding(.top, 1)
                    Text(problem)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 9) {
                ActionButton(title: "Start rebase",
                             icon: "arrow.triangle.merge",
                             prominent: true,
                             busy: state.phase == .rebasing) {
                    state.requestRebase()
                }
                .disabled(state.isBusy)

                ActionButton(title: "Reset plan", icon: "arrow.clockwise") {
                    Task { await state.resetRebasePlan() }
                }
                .disabled(state.isBusy)

                Spacer(minLength: 0)

                if let plan = state.rebasePlan {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(plan.summary)
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                        Text(plan.actionSummary)
                            .font(Theme.micro)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            Text("Nothing is lost: where the branch is now stays in the reflog, so Recovery (\u{2318}4) can put it straight back.")
                .font(Theme.micro)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Row

struct RebaseRow: View {
    let index: Int
    let step: RebaseStep
    let count: Int

    @EnvironmentObject private var state: ProjectSession
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
                    .frame(width: 12)
                    .padding(.top, 2)
                    .help("Drag to reorder")

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(step.commit.shortSha)
                            .font(Theme.mono)
                            .foregroundStyle(.tertiary)
                        Text(step.commit.subject)
                            .font(Theme.bodyEmphasis)
                            .foregroundStyle(step.action == .drop ? .tertiary : .primary)
                            .strikethrough(step.action == .drop, color: Theme.bad.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if step.isMerge {
                            Pill(text: "merge", color: Theme.bad)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(step.commit.author)
                            .font(Theme.micro)
                            .foregroundStyle(.tertiary)
                        Text(step.commit.relativeDate)
                            .font(Theme.micro)
                            .foregroundStyle(.tertiary)
                    }
                }

                VStack(spacing: 1) {
                    QuickAction(icon: "chevron.up", help: "Move earlier") {
                        state.nudgeRebaseStep(at: index, by: -1)
                    }
                    .disabled(index == 0 || state.isBusy)
                    QuickAction(icon: "chevron.down", help: "Move later") {
                        state.nudgeRebaseStep(at: index, by: 1)
                    }
                    .disabled(index >= count - 1 || state.isBusy)
                }
                .opacity(hovering ? 1 : 0.35)
            }

            HStack(spacing: 4) {
                ForEach(RebaseAction.allCases, id: \.self) { action in
                    ActionChoice(action: action,
                                 selected: step.action == action,
                                 enabled: !state.isBusy && !(action == .squash && index == 0)) {
                        state.setRebaseAction(action, at: index)
                    }
                }
                Spacer(minLength: 0)
            }

            if step.action == .reword {
                TextField("New message", text: Binding(
                    get: { step.message },
                    set: { state.setRebaseMessage($0, at: index) }
                ))
                .textFieldStyle(.plain)
                .font(Theme.body)
                .disabled(state.isBusy)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.surface)
                )
            }

            if step.action == .squash {
                Text("Folded into the commit above, which keeps its own message. To change that message, set that commit to REWORD.")
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Theme.surfaceStrong : Theme.surface)
        )
        .onHover { value in
            withAnimation(Theme.snap) { hovering = value }
        }
    }
}

/// One of PICK / SQUASH / REWORD / DROP.
struct ActionChoice: View {
    let action: RebaseAction
    let selected: Bool
    let enabled: Bool
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            Text(action.label)
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(foreground)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(selected ? Color.clear : Theme.hairline, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .onHover { value in
            guard enabled else { return }
            withAnimation(Theme.snap) { hovering = value }
        }
        .help(action.help)
    }

    private var tint: Color {
        switch action {
        case .pick: return Theme.ok
        case .squash: return Color(red: 0.30, green: 0.50, blue: 0.85)
        case .reword: return Theme.warn
        case .drop: return Theme.bad
        }
    }

    private var foreground: Color {
        if selected { return .white }
        return hovering ? .primary : .secondary
    }

    private var fill: Color {
        if selected { return tint }
        return hovering ? Theme.surfaceStrong : .clear
    }
}
