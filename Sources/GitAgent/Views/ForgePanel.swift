import SwiftUI

/// GitHub or GitLab, as an extension of the local repository rather than a copy
/// of the website. It reads through the CLI the user already authenticated, so
/// the app holds no token of its own, and shows nothing at all when that CLI is
/// not there.
struct ForgePanel: View {
    @EnvironmentObject private var state: ProjectSession

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let info = state.forge {
                Text(info.slug)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Pill(text: info.kind.name, color: .secondary)
            } else if state.forgeChecked {
                Text("No GitHub or GitLab remote")
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if state.loadingForge {
                ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 12, height: 12)
            } else {
                QuickAction(icon: "arrow.clockwise", help: "Read it again") {
                    Task { await state.refreshForge(force: true) }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    @ViewBuilder private var content: some View {
        if !state.forgeChecked && state.loadingForge {
            centred {
                ProgressView().controlSize(.small)
                Text("Looking for a host\u{2026}")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let info = state.forge {
            if !info.hasCLI {
                missingCLI(info)
            } else if !info.authenticated {
                notLoggedIn(info)
            } else if info.readsDetail {
                details(info)
            } else {
                browserOnly(info)
            }
        } else {
            centred {
                Image(systemName: "globe")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("This repository's origin is not on GitHub or GitLab.")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func centred<Content: View>(@ViewBuilder _ inner: () -> Content) -> some View {
        VStack(spacing: 9) {
            Spacer()
            inner()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    // MARK: Not ready

    private func missingCLI(_ info: ForgeInfo) -> some View {
        centred {
            Image(systemName: "terminal")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(.tertiary)
            Text("\(info.kind.cli) is not installed.")
                .font(Theme.body)
                .foregroundStyle(.secondary)
            Text("Git Agent reads \(info.kind.name) through the \(info.kind.cli) command line tool, so it never stores a token of its own. Install it and this panel fills in.")
                .font(Theme.micro)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
        }
    }

    private func notLoggedIn(_ info: ForgeInfo) -> some View {
        centred {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(.tertiary)
            Text("\(info.kind.cli) is not logged in.")
                .font(Theme.body)
                .foregroundStyle(.secondary)
            Text("Run this in a terminal, then read it again:")
                .font(Theme.micro)
                .foregroundStyle(.tertiary)
            Text(info.kind.loginHint)
                .font(Theme.mono)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.surface)
                )
        }
    }

    /// GitLab: the actions that need no parsing. Nothing is invented here.
    private func browserOnly(_ info: ForgeInfo) -> some View {
        centred {
            Image(systemName: "arrow.up.forward.square")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(.tertiary)
            Text("\(info.kind.name) is connected.")
                .font(Theme.body)
                .foregroundStyle(.secondary)
            Text("Reading \(info.kind.requestName)s in the panel is GitHub only for now, so rather than guess, these open in your browser.")
                .font(Theme.micro)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
            HStack(spacing: 8) {
                ActionButton(title: "Open \(info.kind.requestName)", icon: "arrow.up.forward") {
                    Task { await state.openForgeRequest() }
                }
                .disabled(state.loadingForge)
                ActionButton(title: "New \(info.kind.requestName)\u{2026}", icon: "plus") {
                    Task { await state.createForgeRequest() }
                }
                .disabled(state.loadingForge)
            }
            if let problem = state.forgeError {
                Text(problem)
                    .font(Theme.micro)
                    .foregroundStyle(Theme.bad)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Ready

    private func details(_ info: ForgeInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let problem = state.forgeError {
                    Text(problem)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }

                thisBranch(info)

                if !state.forgePRs.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        SectionHeader("Open \(info.kind.requestName)s")
                        ForEach(state.forgePRs) { pr in
                            ForgeRequestRow(request: pr, current: pr.number == state.forgePR?.number)
                        }
                    }
                }

                if !state.forgeIssues.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        SectionHeader("Issues assigned to you")
                        ForEach(state.forgeIssues) { issue in
                            Button {
                                state.openForgeURL(issue.url)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 7) {
                                    Text("#\(issue.number)")
                                        .font(Theme.mono)
                                        .foregroundStyle(.tertiary)
                                    Text(issue.title)
                                        .font(Theme.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Text("Read through \(info.kind.cli), which you have already authenticated. Git Agent stores no token and publishes nothing on its own \u{2014} a new \(info.kind.requestName) opens the web form for you to confirm.")
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func thisBranch(_ info: ForgeInfo) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeader("This branch")

            if let pr = state.forgePR {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Text("#\(pr.number)")
                            .font(Theme.mono)
                            .foregroundStyle(.tertiary)
                        Text(pr.title)
                            .font(Theme.bodyEmphasis)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Pill(text: pr.stateLabel,
                             color: pr.isDraft ? .secondary : (pr.isOpen ? Theme.ok : Color(red: 0.55, green: 0.40, blue: 0.75)))
                    }

                    HStack(spacing: 7) {
                        if let checks = pr.checks.label {
                            HStack(spacing: 4) {
                                Image(systemName: pr.checks.isFailing
                                      ? "xmark.circle.fill"
                                      : (pr.checks.isRunning ? "clock" : "checkmark.circle.fill"))
                                    .font(.system(size: 9))
                                    .foregroundStyle(pr.checks.isFailing
                                                     ? Theme.bad
                                                     : (pr.checks.isRunning ? Theme.warn : Theme.ok))
                                Text(checks)
                                    .font(Theme.micro)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("no checks")
                                .font(Theme.micro)
                                .foregroundStyle(.tertiary)
                        }
                        if let review = pr.reviewLabel {
                            Text("\u{00b7}")
                                .font(Theme.micro)
                                .foregroundStyle(.tertiary)
                            Text(review)
                                .font(Theme.micro)
                                .foregroundStyle(pr.reviewDecision == "APPROVED" ? Theme.ok : .secondary)
                        }
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 8) {
                        ActionButton(title: "Open", icon: "arrow.up.forward", prominent: true) {
                            state.openForgeURL(pr.url)
                        }
                        if !pr.checks.isEmpty {
                            ActionButton(title: "Checks", icon: "checklist") {
                                state.openForgeURL(pr.url + "/checks")
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                        .fill(Theme.surface)
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No open \(info.kind.requestName) for \(state.repo?.branchLabel ?? "this branch").")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                    ActionButton(title: "New \(info.kind.requestName)\u{2026}", icon: "plus", prominent: true) {
                        Task { await state.createForgeRequest() }
                    }
                    .disabled(state.loadingForge || state.isBusy)
                    .help("Opens the web form, prefilled from the commits on this branch")
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                        .fill(Theme.surface)
                )
            }
        }
    }
}

// MARK: - Row

struct ForgeRequestRow: View {
    let request: ForgePullRequest
    let current: Bool

    @EnvironmentObject private var state: ProjectSession
    @State private var hovering = false

    var body: some View {
        Button {
            state.openForgeURL(request.url)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("#\(request.number)")
                    .font(Theme.mono)
                    .foregroundStyle(.tertiary)
                Text(request.title)
                    .font(Theme.caption)
                    .foregroundStyle(current ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if request.isDraft {
                    Pill(text: "draft", color: .secondary)
                }
                Spacer(minLength: 4)
                Text(request.branch)
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovering ? Theme.surface : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { value in
            withAnimation(Theme.snap) { hovering = value }
        }
    }
}

// MARK: - Compact chip

/// One line in the compact column when this branch has a request open. The
/// point of the panel is context; this is the part worth seeing without asking.
struct ForgeChip: View {
    @EnvironmentObject private var state: ProjectSession

    var body: some View {
        if let pr = state.forgePR, pr.isOpen {
            Button {
                Task { await state.openForge() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.pull")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text("#\(pr.number)")
                        .font(Theme.mono)
                        .foregroundStyle(.secondary)
                    Text(pr.title)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let checks = pr.checks.label {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(pr.checks.isFailing
                                      ? Theme.bad
                                      : (pr.checks.isRunning ? Theme.warn : Theme.ok))
                                .frame(width: 5, height: 5)
                            Text(checks)
                                .font(Theme.micro)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.surface)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the pull request panel (\u{2318}6)")
        }
    }
}
