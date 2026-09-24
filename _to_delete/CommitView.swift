import AppKit
import SwiftUI

struct CommitView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("COMMIT")
                    .font(Theme.uiTiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
                    .kerning(0.6)

                if let repo = state.repo, repo.hasConflicts {
                    Pill(text: "resolve conflicts first", color: Theme.removed)
                }

                Spacer()

                Button {
                    Task { await state.generateCommitMessage() }
                } label: {
                    HStack(spacing: 3) {
                        if state.generatingMessage {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "sparkles").font(.system(size: 9))
                        }
                        Text(state.commitMessage.isEmpty ? "Generate" : "Regenerate")
                            .font(Theme.uiTiny)
                    }
                }
                .buttonStyle(.link)
                .disabled(state.repo?.hasChanges != true || state.isBusy || state.generatingMessage)
                .help("Ask the Cursor agent for a commit message (\u{2318}\u{21e7}G)")

                if !state.commitMessage.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(state.commitMessage, forType: .string)
                        state.statusMessage = "Commit message copied"
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 9))
                    }
                    .buttonStyle(.link)
                    .help("Copy message")
                }
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.12))
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )

                if state.commitMessage.isEmpty {
                    Text("Commit message")
                        .font(Theme.code)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $state.commitMessage)
                    .font(Theme.code)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
            }
            .frame(height: 54)

            HStack(spacing: 8) {
                Toggle("Stage all on commit", isOn: $state.stageAllBeforeCommit)
                    .toggleStyle(.checkbox)
                    .font(Theme.uiTiny)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Commit") {
                    Task { _ = await state.commit() }
                }
                .disabled(!state.canCommit || state.isBusy)
                .help("Commit staged changes (\u{2318}\u{21a9})")

                Button("Commit & Push\u{2026}") {
                    Task { await state.commitAndPush() }
                }
                .disabled(!state.canCommit || state.isBusy)
                .help("Commit, then confirm the push (\u{2318}\u{21e7}\u{21a9})")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }
}
