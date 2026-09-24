import SwiftUI

/// Sync & Pull, while it happens and after it stopped.
struct SyncPanel: View {
    @EnvironmentObject private var state: ProjectSession

    private var engine: SyncEngine { return state.sync }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headline
                    if let run = engine.run {
                        steps(run)
                        outcome(run)
                    } else {
                        idle
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Hairline()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Headline

    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(engine.run?.phase.progressLabel ?? "Bring this branch up to date.")
                .font(Theme.bodyEmphasis)
                .foregroundStyle(tint)
            Text(subtitle)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tint: Color {
        switch engine.run?.phase {
        case .completed: return Theme.ok
        case .failed: return Theme.bad
        case .conflict: return Theme.warn
        default: return .primary
        }
    }

    private var subtitle: String {
        guard let run = engine.run else {
            let branch = state.repo?.branchLabel ?? "this branch"
            return "Fetches, puts anything uncommitted safely aside, brings \(branch) level with the remote, and puts your work back. Nothing is ever discarded."
        }
        var parts: [String] = []
        if let upstream = run.upstream { parts.append(run.branch + " \u{2192} " + upstream) }
        if run.behindAtStart > 0 { parts.append("\(run.behindAtStart) behind") }
        if run.aheadAtStart > 0 { parts.append("\(run.aheadAtStart) ahead") }
        if run.finishedAt != nil { parts.append(run.durationLabel) }
        return parts.joined(separator: " \u{00b7} ")
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(SyncPanel.preview, id: \.self) { line in
                HStack(spacing: 7) {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 8))
                        .foregroundStyle(.quaternary)
                    Text(line)
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private static let preview = [
        "Check the repository",
        "Protect local changes",
        "Fetch from the remote",
        "Synchronize the branch",
        "Restore local changes",
        "Verify the result"
    ]

    // MARK: Steps

    private func steps(_ run: SyncRun) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(run.steps) { step in
                SyncStepRow(step: step)
            }
        }
    }

    // MARK: Outcome

    @ViewBuilder private func outcome(_ run: SyncRun) -> some View {
        if let problem = run.problem {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(run.phase == .conflict ? "Stopped safely" : "What went wrong")
                Text(problem)
                    .font(Theme.body)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = run.hint {
                    Text(hint)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !run.conflicts.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(run.conflicts, id: \.self) { path in
                            Button {
                                state.detail = .conflict(path)
                                state.applyWindowWidth()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 8))
                                        .foregroundStyle(Theme.warn)
                                    Text(path)
                                        .font(Theme.mono)
                                        .foregroundStyle(Theme.accent)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 2)
                }
                if let technical = run.technical, !technical.isEmpty {
                    DisclosureGroup("Technical details") {
                        Text(technical)
                            .font(Theme.mono)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                }
            }
        }

        if run.workIsParked {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your \(run.stashedCount) change\(run.stashedCount == 1 ? "" : "s") are in the stash")
                        .font(Theme.caption)
                    Text("Nothing was deleted. Open the stash to put them back whenever you are ready.")
                        .font(Theme.micro)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open the stash") { Task { await state.openStashes() } }
                        .buttonStyle(.plain)
                        .font(Theme.micro)
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.surface)
            )
        }

        if run.phase == .completed {
            Text("Remote updated \u{00b7} local changes preserved.")
                .font(Theme.micro)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 9) {
            ActionButton(title: engine.run == nil ? "Sync & Pull" : "Sync again",
                         icon: "arrow.triangle.2.circlepath",
                         prominent: true,
                         busy: engine.running) {
                engine.start()
            }
            .disabled(!engine.canStart)
            .help(engine.canStart
                  ? "Fetch, protect what is uncommitted, bring the branch up to date, put it back"
                  : (state.busyLabel ?? "Nothing to synchronize"))

            if state.repo?.hasConflicts == true {
                ActionButton(title: "Resolve conflicts", icon: "exclamationmark.triangle.fill") {
                    Task { await state.openAllChanges() }
                }
            }

            Spacer(minLength: 0)

            if engine.running {
                Text("Running \u{2014} nothing else touches this repository meanwhile.")
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
            } else if engine.run != nil {
                Button("Clear") { engine.clear() }
                    .buttonStyle(.plain)
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - One step

private struct SyncStepRow: View {
    let step: SyncStep

    @EnvironmentObject private var state: ProjectSession
    @State private var hovering = false

    private var engine: SyncEngine { return state.sync }
    private var isOpen: Bool { return engine.openStep == step.id }
    private var hasOutput: Bool { return !step.output.isEmpty }

    @ViewBuilder private var marker: some View {
        if step.state == .running {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)
        } else {
            Image(systemName: Theme.icon(for: step.state))
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Theme.color(for: step.state))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard hasOutput else { return }
                withAnimation(Theme.ease) { engine.openStep = isOpen ? nil : step.id }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    marker
                        .frame(width: 14)
                    Text(step.title)
                        .font(Theme.body)
                        .foregroundStyle(step.state == .pending || step.state == .skipped ? .tertiary : .primary)
                    if let detail = step.detail, !detail.isEmpty {
                        Text(detail)
                            .font(Theme.micro)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    if hasOutput {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOpen ? Theme.surfaceStrong : (hovering ? Theme.surface : .clear))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { value in
                withAnimation(Theme.snap) { hovering = value }
            }

            if isOpen {
                Text(step.output)
                    .font(Theme.mono)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }
        }
    }
}
