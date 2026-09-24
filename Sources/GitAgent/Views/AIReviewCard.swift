import SwiftUI

// MARK: - Summary strip

struct SummaryStrip: View {
    @EnvironmentObject private var state: ProjectSession

    var body: some View {
        if let repo = state.repo, repo.hasChanges {
            HStack(spacing: 8) {
                DiffCounts(additions: repo.totalAdditions,
                           deletions: repo.totalDeletions,
                           boxed: true,
                           showsIcon: true)
                Spacer(minLength: 6)
                if repo.isMerging {
                    Text("merging")
                        .font(Theme.micro)
                        .foregroundStyle(Theme.warn)
                }
                Text("\(repo.changes.count) file\(repo.changes.count == 1 ? "" : "s")")
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - Conflicts

struct ConflictBanner: View {
    @EnvironmentObject private var state: ProjectSession

    var body: some View {
        if let repo = state.repo, repo.hasConflicts {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.bad)
                    Text("\(repo.conflicts.count) conflict\(repo.conflicts.count == 1 ? "" : "s")")
                        .font(Theme.bodyEmphasis)
                    if repo.isRebasing {
                        Text("mid rebase")
                            .font(Theme.micro)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    if repo.conflicts.count > 1 {
                        ActionButton(title: "Resolve all", icon: Theme.aiMark, prominent: true) {
                            Task { await state.resolveAllConflicts(continuingRebase: repo.isRebasing) }
                        }
                        .disabled(!state.aiCanEditFiles || state.isBusy)
                        .help(state.aiCanEditFiles
                              ? "Hands every conflicted file to the agent"
                              : (state.aiProblem ?? "\(state.aiProviderLabel) cannot write files"))
                    }
                }

                ForEach(repo.conflicts) { conflict in
                    HStack(spacing: 8) {
                        Button {
                            Task { await state.open(change: conflict) }
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(conflict.fileName)
                                    .font(Theme.body)
                                    .lineLimit(1)
                                if !conflict.directory.isEmpty {
                                    Text(conflict.directory)
                                        .font(Theme.micro)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        ActionButton(title: "Resolve with AI", icon: Theme.aiMark) {
                            Task {
                                await state.open(change: conflict)
                                await state.resolveConflict(conflict)
                            }
                        }
                        .disabled(!state.aiCanEditFiles || state.isBusy || state.resolvingConflict)
                        .help(state.aiCanEditFiles
                              ? "Opens the conflict and asks the agent to merge both sides"
                              : (state.aiProblem ?? "\(state.aiProviderLabel) cannot write files"))
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.bad.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Theme.bad.opacity(0.22), lineWidth: 1)
            )
        }
    }
}

// MARK: - AI review

struct AIReviewCard: View {
    @EnvironmentObject private var state: ProjectSession
    @State private var showSuggestions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: Theme.aiMark)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                Text("AI REVIEW")
                    .font(Theme.sectionLabel)
                    .kerning(0.8)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                riskPill
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .animation(Theme.ease, value: state.phase)
    }

    @ViewBuilder private var riskPill: some View {
        if let review = state.review, review.parsed, review.risk == .medium || review.risk == .high {
            Pill(text: "risk \(review.risk.label.lowercased())", color: Theme.tint(for: review.risk))
        }
    }

    @ViewBuilder private var content: some View {
        if !state.aiAvailable {
            providerMissing
        } else if state.phase == .reviewing {
            analyzing
        } else if let message = state.reviewError {
            failed(message)
        } else if let review = state.review {
            result(review)
        } else if state.repo?.hasChanges == true {
            idle
        } else {
            nothingToDo
        }
    }

    // MARK: States

    private var providerMissing: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("\(state.aiProviderLabel) is not ready")
                .font(Theme.bodyEmphasis)
            Text(state.aiProblem ?? "Set up an AI provider to review changes.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ActionButton(title: "Open Settings", icon: "gearshape") {
                AppActions.openSettings()
            }
        }
    }

    private var nothingToDo: some View {
        Text("Nothing to analyze \u{2014} the working tree is clean.")
            .font(Theme.caption)
            .foregroundStyle(.secondary)
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Understand these changes")
                .font(Theme.bodyEmphasis)
            Text("The agent reads the diff and the files around it, then reports what changed and what looks wrong.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ActionButton(title: "Review Changes", icon: Theme.aiMark, prominent: true) {
                Task { await state.reviewChanges() }
            }
            .disabled(state.isBusy)
        }
    }

    private var analyzing: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Analyzing your changes")
                .font(Theme.bodyEmphasis)

            VStack(alignment: .leading, spacing: 6) {
                StepRow(index: 0, current: state.reviewStep,
                        text: "Reading \(state.repo?.changes.count ?? 0) files")
                StepRow(index: 1, current: state.reviewStep, text: "Understanding relationships")
                StepRow(index: 2, current: state.reviewStep, text: "Checking for potential issues")
            }

            if let last = state.agentActivity.last(where: { $0.kind == .tool || $0.kind == .agent }) {
                Text(last.text)
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .transition(.opacity)
            }

            Button("Cancel") { state.cancelAgent() }
                .buttonStyle(.link)
                .font(Theme.micro)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.bad)
                Text("Review failed")
                    .font(Theme.bodyEmphasis)
            }
            Text(message)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ActionButton(title: "Try again", icon: "arrow.clockwise") {
                    Task { await state.reviewChanges() }
                }
                .disabled(state.isBusy)
                Button("Activity") { state.openActivity() }
                    .buttonStyle(.link)
                    .font(Theme.micro)
            }
        }
    }

    private func result(_ review: ReviewResult) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: headline(review).icon)
                    .font(.system(size: 11))
                    .foregroundStyle(headline(review).tint)
                Text(headline(review).text)
                    .font(Theme.bodyEmphasis)
            }

            if review.parsed {
                if !review.summary.isEmpty {
                    Text(review.summary)
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if review.findings.isEmpty {
                    Text("The agent reported nothing to look at in these changes.")
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 4) {
                        ForEach(review.findings) { finding in
                            FindingRow(finding: finding)
                        }
                    }
                }

                suggestions(review)
            } else {
                Text(review.rawText)
                    .font(Theme.code)
                    .foregroundStyle(.secondary)
                    .lineLimit(12)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !state.touchedFiles.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "pencil")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.accentColor)
                    Text("AI changed \(state.touchedFiles.count) file\(state.touchedFiles.count == 1 ? "" : "s")")
                        .font(Theme.micro)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                ActionButton(title: "Review again", icon: "arrow.clockwise") {
                    Task { await state.reviewChanges() }
                }
                .disabled(state.isBusy)

                if let first = review.issues.first {
                    ActionButton(title: "Fix with AI", icon: Theme.aiMark, prominent: true) {
                        Task { await state.openProblem(first) }
                    }
                    .disabled(state.isBusy)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 1)
        }
    }

    /// One line that says what the review concluded.
    private func headline(_ review: ReviewResult) -> (text: String, icon: String, tint: Color) {
        guard review.parsed else { return ("Analysis complete", "checkmark.circle", Theme.ok) }
        let issues = review.issues.count
        if issues == 0 {
            let passed = review.findings.count
            let text = passed > 0 ? "Looks good \u{00b7} \(passed) check\(passed == 1 ? "" : "s") passed" : "Looks good"
            return (text, "checkmark.circle.fill", Theme.ok)
        }
        let worst = review.issues.contains { $0.kind == .risk } ? Theme.bad : Theme.warn
        return ("\(issues) issue\(issues == 1 ? "" : "s") found", "exclamationmark.triangle.fill", worst)
    }

    @ViewBuilder private func suggestions(_ review: ReviewResult) -> some View {
        if !review.suggestions.isEmpty {
            Button {
                withAnimation(Theme.ease) { showSuggestions.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .rotationEffect(.degrees(showSuggestions ? 90 : 0))
                    Text("\(review.suggestions.count) suggestion\(review.suggestions.count == 1 ? "" : "s")")
                        .font(Theme.micro)
                }
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showSuggestions {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(review.suggestions.enumerated()), id: \.offset) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(Color.secondary.opacity(0.4))
                                .frame(width: 3, height: 3)
                                .padding(.top, 5)
                            Text(item.element)
                                .font(Theme.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Pieces

struct StepRow: View {
    let index: Int
    let current: Int
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            marker
                .frame(width: 11, height: 11)
            Text(text)
                .font(Theme.caption)
                .foregroundStyle(index <= current ? Color.secondary : Color.secondary.opacity(0.4))
        }
        .animation(Theme.ease, value: current)
    }

    @ViewBuilder private var marker: some View {
        if index < current {
            Image(systemName: "checkmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Theme.ok)
        } else if index == current {
            PulsingDot()
        } else {
            Circle()
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                .frame(width: 6, height: 6)
        }
    }
}

/// A single review finding. Passing checks are quiet; issues open in the panel.
struct FindingRow: View {
    let finding: AIProblem
    @EnvironmentObject private var state: ProjectSession
    @State private var hovering = false

    var body: some View {
        Group {
            if finding.kind.isIssue {
                Button {
                    Task { await state.openProblem(finding) }
                } label: {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
        .onHover { value in
            withAnimation(Theme.snap) { hovering = value }
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 11)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(finding.title)
                    .font(Theme.body)
                    .foregroundStyle(finding.kind.isIssue ? .primary : .secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                if let location = finding.location {
                    Text(location)
                        .font(Theme.micro)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                if finding.kind.isIssue && !finding.detail.isEmpty {
                    Text(finding.detail)
                        .font(Theme.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 4)

            if finding.kind.isIssue {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0.4)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(background)
        )
        .contentShape(Rectangle())
    }

    private var icon: String {
        switch finding.kind {
        case .ok: return "checkmark"
        case .warning: return "exclamationmark.triangle.fill"
        case .risk: return "exclamationmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch finding.kind {
        case .ok: return Theme.ok
        case .warning: return Theme.warn
        case .risk: return Theme.bad
        }
    }

    private var background: Color {
        guard finding.kind.isIssue else { return .clear }
        return hovering ? Theme.surfaceStrong : Theme.surface
    }
}
