import SwiftUI

/// Conflict resolution as its own experience: both sides, then what the agent
/// decided and why. Nothing is applied without the user asking for it.
struct ConflictPanel: View {
    let change: FileChange
    @EnvironmentObject private var state: ProjectSession

    var body: some View {
        VSplitView {
            HStack(spacing: 0) {
                ConflictSide(title: "Current",
                             subtitle: state.repo?.branchLabel,
                             code: state.conflictCurrent)
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 1)
                ConflictSide(title: "Incoming",
                             subtitle: "merging",
                             code: state.conflictIncoming)
            }
            .frame(minHeight: 160, idealHeight: 320)

            resolution
                .frame(minHeight: 150)
        }
    }

    private var resolution: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader(title: "AI Resolution") {
                if state.conflictResolution != nil {
                    Button("Show resulting diff") {
                        state.detail = .file(change.path)
                    }
                    .buttonStyle(.link)
                    .font(Theme.micro)
                }
            }

            if state.resolvingConflict {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                    Text(state.agentActivity.last?.text ?? "Reading both sides\u{2026}")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else if let resolution = state.conflictResolution {
                ScrollView {
                    Text(resolution)
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 10) {
                    ActionButton(title: "Apply Resolution", icon: "checkmark", prominent: true) {
                        Task { await state.markResolved(change) }
                    }
                    .disabled(state.isBusy)
                    .help("Stages the resolved file. Nothing is committed.")

                    Button("Resolve again") {
                        Task { await state.resolveConflict(change) }
                    }
                    .buttonStyle(.link)
                    .font(Theme.micro)
                    .disabled(state.isBusy || !state.aiCanEditFiles)

                    Spacer(minLength: 0)
                }
            } else {
                Text(state.aiCanEditFiles
                     ? "The agent reads both sides, the history and the surrounding code, then rewrites the file without conflict markers. It never stages or commits."
                     : "\(state.aiProviderLabel) answers with text, so it cannot rewrite the file itself. Switch the provider to the Cursor CLI in Settings, or resolve this one by hand and mark it resolved.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    ActionButton(title: "Resolve with AI",
                                 icon: Theme.aiMark,
                                 prominent: true,
                                 busy: state.resolvingConflict) {
                        Task { await state.resolveConflict(change) }
                    }
                    .disabled(state.isBusy || !state.aiCanEditFiles)
                    .help(state.aiCanEditFiles
                          ? "Asks the agent to merge both sides"
                          : (state.aiProblem ?? "\(state.aiProviderLabel) cannot write files"))

                    Button("Mark as resolved") {
                        Task { await state.markResolved(change) }
                    }
                    .buttonStyle(.link)
                    .font(Theme.micro)
                    .help("Use this after resolving the file yourself")

                    Spacer(minLength: 0)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ConflictSide: View {
    let title: String
    let subtitle: String?
    let code: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(Theme.sectionLabel)
                    .kerning(0.8)
                    .foregroundStyle(.tertiary)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.micro)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 26)

            Hairline()

            ScrollView([.vertical, .horizontal]) {
                Text(code ?? "This side is not available.")
                    .font(Theme.code)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
