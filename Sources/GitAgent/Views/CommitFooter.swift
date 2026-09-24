import AppKit
import SwiftUI

struct CommitFooter: View {
    @EnvironmentObject private var state: ProjectSession
    @FocusState private var editorFocused: Bool
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            Hairline()

            VStack(alignment: .leading, spacing: 8) {
                header
                editor
                caption
                syncRow
                actions
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .onChange(of: state.generatedMessage) { value in
            guard value != nil else { return }
            withAnimation(Theme.ease) { pulse = true }
            Task {
                try? await Task.sleep(nanoseconds: 900_000_000)
                withAnimation(.easeOut(duration: 0.5)) { pulse = false }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "smallcircle.filled.circle")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text("COMMIT")
                .font(Theme.sectionLabel)
                .kerning(0.8)
                .foregroundStyle(.tertiary)

            Spacer(minLength: 4)

            Button {
                Task { await state.generateCommitMessage() }
            } label: {
                HStack(spacing: 4) {
                    if state.generatingMessage {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.5)
                            .frame(width: 10, height: 10)
                    } else {
                        Image(systemName: Theme.aiMark)
                            .font(.system(size: 8.5, weight: .bold))
                    }
                    Text(state.commitMessage.isEmpty ? "Generate" : "Regenerate")
                        .font(Theme.micro)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.link)
            .disabled(state.repo?.hasChanges != true || state.isBusy || state.generatingMessage || !state.aiAvailable)
            .help("Write the commit message from the current changes (\u{2318}\u{21e7}G)")
        }
    }

    // MARK: Editor

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.surface)

            if state.commitMessage.isEmpty {
                Text("Describe this change")
                    .font(Theme.mono)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $state.commitMessage)
                .font(Theme.mono)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
        }
        .frame(height: 52)
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .overlay(alignment: .bottomTrailing) {
            if !state.commitMessage.isEmpty {
                Text("\(subjectLength)")
                    .font(Theme.micro)
                    .monospacedDigit()
                    .foregroundStyle(subjectLength > 72 ? Theme.warn : Color.secondary.opacity(0.5))
                    .padding(.trailing, 7)
                    .padding(.bottom, 4)
                    .allowsHitTesting(false)
            }
        }
        .animation(Theme.ease, value: editorFocused)
    }

    private var borderColor: Color {
        if pulse { return Color.accentColor.opacity(0.55) }
        if editorFocused { return Color.accentColor.opacity(0.35) }
        return Theme.hairline
    }

    private var subjectLength: Int {
        let first = state.commitMessage.split(separator: "\n", omittingEmptySubsequences: false).first
        return first.map { $0.count } ?? 0
    }

    // MARK: Caption and actions

    @ViewBuilder private var caption: some View {
        if let generated = state.generatedMessage, generated == state.commitMessage, !generated.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: Theme.aiMark)
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.tertiary)
                Text("Generated from the current changes")
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                Button("Edit") { editorFocused = true }
                    .buttonStyle(.link)
                    .font(Theme.micro)
            }
            .transition(.opacity)
        }
    }

    /// A failed push keeps its reason here, and a branch that is behind gets a
    /// pull right where the action is.
    @ViewBuilder private var syncRow: some View {
        if let problem = state.pushProblem {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.bad)
                    .padding(.top, 1)
                Text(problem)
                    .font(Theme.micro)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                // The way out of a rejected push is to sync, so the button
                // that does it has to be HERE. It used to live in the "you are
                // behind" row below, which this bar replaced: the one moment
                // the user needs it is the one moment it disappeared.
                VStack(alignment: .trailing, spacing: 3) {
                    if (state.repo?.behind ?? 0) > 0 {
                        Button("Sync & Pull") { state.syncAndPull() }
                            .buttonStyle(.link)
                            .font(Theme.micro)
                            .disabled(state.isBusy)
                    }
                    Button("Retry") { state.requestPush() }
                        .buttonStyle(.link)
                        .font(Theme.micro)
                        .foregroundStyle(.secondary)
                        .disabled(state.isBusy)
                }
                .fixedSize()
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.bad.opacity(0.09))
            )
        } else if let repo = state.repo, repo.behind > 0 {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.warn)
                Text("origin/\(repo.branch) has \(repo.behind) commit\(repo.behind == 1 ? "" : "s") you do not have")
                    .font(Theme.micro)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                // Sync rather than Pull: with work in the tree a plain pull
                // refuses, and that refusal was the whole complaint.
                Button("Sync & Pull") { state.syncAndPull() }
                    .buttonStyle(.link)
                    .font(Theme.micro)
                    .disabled(state.isBusy)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.surface)
            )
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if let blocker {
                Text(blocker)
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            if case .commitAndPush = state.primaryAction {
                ActionButton(title: "Commit", busy: state.phase == .committing) {
                    Task { _ = await state.commit() }
                }
                .disabled(!state.canCommit || state.isBusy)
                .help("Commit without pushing (\u{2318}\u{21a9})")
            }

            ActionButton(title: state.primaryAction.title,
                         icon: state.primaryAction.icon,
                         prominent: true,
                         busy: state.phase == .committing || state.phase == .pushing) {
                Task { await state.runPrimaryAction() }
            }
            .disabled(!state.primaryActionReady)
            .help(primaryHelp)
        }
    }

    /// Why the main action cannot run yet, if it cannot.
    private var blocker: String? {
        guard case .commitAndPush = state.primaryAction else { return nil }
        if state.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Write or generate a message"
        }
        if let repo = state.repo, repo.stagedChanges.isEmpty, !state.stageAllBeforeCommit {
            return "Tick the files to include"
        }
        return nil
    }

    private var primaryHelp: String {
        switch state.primaryAction {
        case .commitAndPush:
            return "Commit the changes, then confirm the push (\u{2318}\u{21e7}\u{21a9})"
        case .push:
            return "Push the commits that are not on origin yet"
        case .resolveConflicts:
            return "Resolve the conflicts first"
        case .upToDate:
            return "Nothing to commit or push"
        }
    }

}
