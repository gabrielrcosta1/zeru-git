import SwiftUI

/// Where the current branch has been, read from git's own reflog, and the two
/// ways back. Nothing here is a backup: the commits are still in the repository
/// until git prunes them, and this only builds a ref that reaches them again.
struct RecoveryPanel: View {
    @EnvironmentObject private var state: ProjectSession
    @State private var openPoint: String?

    var body: some View {
        VStack(spacing: 0) {
            content
            Hairline()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var content: some View {
        if let repo = state.repo, repo.detached {
            PanelPlaceholder(text: "HEAD is detached. Check out a branch to see where it has been.")
        } else if !state.recoveryLoaded && state.recoveryPoints.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                ProgressView().controlSize(.small)
                Text("Reading the reflog\u{2026}")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.recoveryReadFailed {
            VStack(spacing: 9) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(Theme.warn)
                Text("Could not read this branch's reflog.")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                ActionButton(title: "Try Again", icon: "arrow.clockwise") {
                    Task { await state.refreshRecovery(deep: true) }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)
        } else if state.recoveryPoints.isEmpty {
            PanelPlaceholder(text: "This branch has only ever been in one place.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(state.recoveryPoints) { point in
                        RecoveryRow(point: point,
                                    isLatest: state.recoveryPoints.first?.id == point.id,
                                    isOpen: openPoint == point.id) {
                            withAnimation(Theme.ease) {
                                openPoint = openPoint == point.id ? nil : point.id
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 6) {
            if state.loadingRecovery {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .frame(width: 12, height: 12)
                    .padding(.top, 1)
            } else {
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
            }
            Text("Git keeps every position of a branch for a while, in its reflog. A commit that left the branch is still in the repository until git prunes it, so restoring it costs nothing.")
                .font(Theme.micro)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - Row

struct RecoveryRow: View {
    let point: RecoveryPoint
    let isLatest: Bool
    let isOpen: Bool
    let onToggle: () -> Void

    @EnvironmentObject private var state: ProjectSession
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                header
            }
            .buttonStyle(.plain)
            .onHover { value in
                withAnimation(Theme.snap) { hovering = value }
            }

            if isOpen {
                details
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isOpen ? Theme.surfaceStrong : (hovering ? Theme.surface : Color.clear))
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(point.entry.action)
                        .font(Theme.bodyEmphasis)
                    Text(point.entry.relative)
                        .font(Theme.micro)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    if point.isLoss {
                        Pill(text: "\u{2212}" + point.lostLabel, color: Theme.warn)
                    } else if point.isRewriteOnly {
                        Pill(text: point.rewrittenLabel, color: .secondary)
                    } else if point.counted {
                        Text("nothing left the branch")
                            .font(Theme.micro)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("not counted")
                            .font(Theme.micro)
                            .foregroundStyle(.quaternary)
                    }
                }
                if !point.entry.message.isEmpty {
                    Text(point.entry.message)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(point.shortFrom)
                    .font(Theme.mono)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Image(systemName: "arrow.right")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.tertiary)
                Text(point.entry.shortSha)
                    .font(Theme.mono)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }

            if point.isLoss {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Left the branch")
                        .font(Theme.sectionLabel)
                        .kerning(0.8)
                        .foregroundStyle(.tertiary)
                    ForEach(point.lost) { commit in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(commit.shortSha)
                                .font(Theme.mono)
                                .foregroundStyle(.tertiary)
                            Text(commit.subject)
                                .font(Theme.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            Text(commit.relativeDate)
                                .font(Theme.micro)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if point.moreLost {
                        Text("and more")
                            .font(Theme.micro)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else if point.isRewriteOnly {
                Text("\(point.rewrittenLabel) under a new sha, which is what a rebase does. The old shas are gone, the work is not, and there is nothing missing to recover.")
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !point.counted {
                Text("Git could not say what this move left behind \u{2014} one of the two commits is no longer in the repository.")
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actions
        }
        .padding(.horizontal, 27)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var actions: some View {
        let blocker = isLatest ? state.moveBackBlocker(point) : nil

        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if point.isLoss {
                    if isLatest {
                        ActionButton(title: "Move \(point.branch) back",
                                     icon: "arrow.counterclockwise",
                                     prominent: true) {
                            state.requestMoveBack(point)
                        }
                        .disabled(state.isBusy || blocker != nil)
                        .help(blocker ?? "Puts \(point.branch) back at \(point.shortFrom). Anything staged comes back unstaged.")

                        // A dirty tree is the one obstacle with a single step
                        // out of it, so that step is right here.
                        if blocker != nil, state.onlyNeedsStash(point) {
                            ActionButton(title: "Stash changes", icon: "tray.and.arrow.down") {
                                Task { await state.stashChanges() }
                            }
                            .disabled(state.isBusy)
                            .help("Parks your uncommitted work so the branch can move. Pop it afterwards from Stashes (\u{2318}3).")
                        }
                    }

                    ActionButton(title: "Restore as branch", icon: "arrow.triangle.branch") {
                        Task { await state.restoreAsBranch(point) }
                    }
                    .disabled(state.isBusy)
                    .help("Creates recovered/\(point.shortFrom) at that commit. Nothing else moves, and it works with a dirty tree.")
                } else if point.isRewriteOnly {
                    Text("Nothing is missing, so there is nothing to recover.")
                        .font(Theme.micro)
                        .foregroundStyle(.tertiary)
                } else if point.counted {
                    Text("This move only added commits, so there is nothing to recover.")
                        .font(Theme.micro)
                        .foregroundStyle(.tertiary)
                } else {
                    ActionButton(title: "Restore as branch", icon: "arrow.triangle.branch") {
                        Task { await state.restoreAsBranch(point) }
                    }
                    .disabled(state.isBusy)
                    .help("Creates a branch at \(point.shortFrom) anyway. Nothing else moves.")
                }
                Spacer(minLength: 0)
            }

            if let blocker, point.isLoss {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.warn)
                        .padding(.top, 1)
                    Text(blocker)
                        .font(Theme.micro)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Banner

/// Appears when commits left the branch and it was not something the app was
/// asked to do: a reset or a rebase from a terminal, most of the time.
struct RecoveryBanner: View {
    @EnvironmentObject private var state: ProjectSession

    var body: some View {
        if let point = state.recoveryBanner {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.warn)
                    Text("\(point.entry.action) removed \(point.lostLabel)")
                        .fixedSize(horizontal: false, vertical: true)
                        .font(Theme.bodyEmphasis)
                    Text(point.entry.relative)
                        .font(Theme.micro)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    Button {
                        state.dismissRecoveryBanner()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Hide this")
                }

                ForEach(point.lost.prefix(3)) { commit in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(commit.shortSha)
                            .font(Theme.mono)
                            .foregroundStyle(.tertiary)
                        Text(commit.subject)
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                }

                HStack(spacing: 8) {
                    ActionButton(title: "Recover\u{2026}", icon: "arrow.counterclockwise", prominent: true) {
                        Task { await state.openRecovery() }
                    }
                    .disabled(state.isBusy)
                    Text("they are still in the repository")
                        .font(Theme.micro)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .fill(Theme.warn.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .strokeBorder(Theme.warn.opacity(0.28), lineWidth: 1)
            )
        }
    }
}
