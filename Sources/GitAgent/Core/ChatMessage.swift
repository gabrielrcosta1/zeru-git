import Foundation

/// One line of the conversation with the agent.
///
/// The plan itself is not kept here: it lives on the session, where the plan
/// panel, the allowlist and the confirmation already are. A message only
/// remembers that it produced one, and how many commands it had.
struct ChatMessage: Identifiable, Hashable {
    enum Role: Hashable {
        case you
        case agent
    }

    let id = UUID()
    let role: Role
    var text: String
    /// How many git commands the answer proposed, when it proposed any.
    var planSteps: Int = 0
    /// The agent could not answer at all: shown as a failure, not as advice.
    var failed = false
    let date = Date()
}
