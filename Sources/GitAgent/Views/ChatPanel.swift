import SwiftUI

/// Asking for something in your own words. The answer is text; when the answer
/// is "run these commands", the plan opens in the panel that already knows how
/// to run one.
struct ChatPanel: View {
    @EnvironmentObject private var state: ProjectSession
    @FocusState private var writing: Bool

    private var thinking: Bool { return state.phase == .answering }

    var body: some View {
        VStack(spacing: 0) {
            if state.aiAvailable {
                conversation
                Hairline()
                composer
            } else {
                providerMissing
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { writing = true }
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if state.chat.isEmpty {
                        empty
                    }
                    ForEach(state.chat) { message in
                        MessageRow(message: message, isLast: message.id == state.chat.last?.id)
                            .id(message.id)
                    }
                    if thinking {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                            Text("Thinking\u{2026}")
                                .font(Theme.caption)
                                .foregroundStyle(.secondary)
                        }
                        .id(Self.thinkingAnchor)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: state.chat.count) { _ in
                guard let last = state.chat.last?.id else { return }
                withAnimation(Theme.ease) { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onChange(of: state.phase) { _ in
                guard thinking else { return }
                withAnimation(Theme.ease) { proxy.scrollTo(Self.thinkingAnchor, anchor: .bottom) }
            }
        }
    }

    private static let thinkingAnchor = "chat-thinking"

    private var empty: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Ask for what you want.")
                .font(Theme.bodyEmphasis)
            Text("Plain words. If the answer needs git commands, they come back as a plan you can look at before anything runs.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Self.examples, id: \.self) { example in
                    Button {
                        state.chatDraft = example
                        writing = true
                    } label: {
                        Text(example)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
        }
        .padding(.bottom, 4)
    }

    private static let examples = [
        "Why did the last pull fail?",
        "Move my last commit to a new branch",
        "Undo the last commit but keep the files"
    ]

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 7) {
            TextField("Ask about this repository\u{2026}",
                      text: $state.chatDraft,
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .lineLimit(1...5)
                .focused($writing)
                .onSubmit(send)
                .disabled(state.isBusy)

            HStack(spacing: 8) {
                if !state.chat.isEmpty {
                    Button("Clear") { state.clearChat() }
                        .buttonStyle(.plain)
                        .font(Theme.micro)
                        .foregroundStyle(.tertiary)
                        .disabled(state.isBusy)
                }
                Spacer(minLength: 0)
                // Only when a step is actually blocked: a plan that merely
                // contains a destructive command is not waiting for anything.
                if state.pendingStep != nil {
                    Text("A step is waiting for your confirmation")
                        .font(Theme.micro)
                        .foregroundStyle(.secondary)
                }
                ActionButton(title: "Send", icon: "arrow.up", prominent: true, busy: thinking) {
                    send()
                }
                .disabled(state.isBusy || state.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func send() {
        guard !state.isBusy else { return }
        Task { await state.sendChat() }
    }

    // MARK: - No provider

    private var providerMissing: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("\(state.aiProviderLabel) is not ready")
                .font(Theme.bodyEmphasis)
            Text(state.aiProblem ?? "Set up an AI provider to ask it anything.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ActionButton(title: "Open Settings", icon: "gearshape") {
                AppActions.openSettings()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - One message

private struct MessageRow: View {
    @EnvironmentObject private var state: ProjectSession
    let message: ChatMessage
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(message.role == .you ? "YOU" : "AGENT")
                .font(Theme.micro)
                .tracking(0.6)
                .foregroundStyle(.tertiary)

            Text(message.text)
                .font(Theme.body)
                .foregroundStyle(message.failed ? Theme.removed : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            // Only the newest answer points at the plan: the session holds one
            // plan, and an older row would open somebody else's.
            if isLast, message.planSteps > 0, state.plan != nil {
                ActionButton(title: planTitle, icon: "list.bullet.rectangle") {
                    state.detail = .plan
                    state.applyWindowWidth()
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var planTitle: String {
        let count = message.planSteps
        return count == 1 ? "See the command" : "See the \(count) commands"
    }
}
