import AppKit
import Combine
import Foundation

/// Settings that belong to the app, not to a project. One instance, shared by
/// every open tab.
@MainActor
final class AppSettings: ObservableObject {

    @Published var floatOnTop: Bool = Defaults.bool("floatOnTop", false) {
        didSet {
            Defaults.set("floatOnTop", floatOnTop)
            onFloatOnTopChange?()
        }
    }
    @Published var cursorBinaryPath: String = Defaults.string("cursorBinaryPath", "") {
        didSet {
            Defaults.set("cursorBinaryPath", cursorBinaryPath)
            detectCLI()
        }
    }
    @Published var cursorModel: String = Defaults.string("cursorModel", "") {
        didSet { Defaults.set("cursorModel", cursorModel) }
    }
    @Published var stageAllBeforeCommit: Bool = Defaults.bool("stageAllBeforeCommit", true) {
        didSet { Defaults.set("stageAllBeforeCommit", stageAllBeforeCommit) }
    }
    /// After a pull that conflicts, hand the conflicts to the agent instead of
    /// leaving the repository mid rebase.
    @Published var resolveConflictsWithAI: Bool = Defaults.bool("resolveConflictsWithAI", true) {
        didSet { Defaults.set("resolveConflictsWithAI", resolveConflictsWithAI) }
    }

    /// Which half of the Activity panel is showing. It belongs to the app, not
    /// to a project: switching tabs must not flip it.
    @Published var activityMode: ActivityMode =
        ActivityMode(rawValue: Defaults.string("activityMode", ActivityMode.timeline.rawValue)) ?? .timeline {
        didSet { Defaults.set("activityMode", activityMode.rawValue) }
    }

    // MARK: - AI provider

    /// Which engine answers. The CLI stays the default: it is the only one that
    /// can read and write files.
    @Published var aiProvider: AIProviderKind =
        AIProviderKind(rawValue: Defaults.string("aiProvider", AIProviderKind.cursor.rawValue)) ?? .cursor {
        didSet { Defaults.set("aiProvider", aiProvider.rawValue) }
    }

    /// Bumped after a Keychain write, so the views notice. The keys themselves
    /// are never held in a property.
    @Published private(set) var keyRevision = 0
    private var keyPresence: [String: Bool] = [:]

    /// One model per provider: switching provider must not carry a model name
    /// the new one has never heard of.
    func model(for kind: AIProviderKind) -> String {
        return Defaults.string("aiModel." + kind.rawValue, "")
    }

    func setModel(_ value: String, for kind: AIProviderKind) {
        Defaults.set("aiModel." + kind.rawValue, value.trimmingCharacters(in: .whitespacesAndNewlines))
        objectWillChange.send()
    }

    func baseURL(for kind: AIProviderKind) -> String {
        let stored = Defaults.string("aiBaseURL." + kind.rawValue, "")
        return stored.isEmpty ? kind.defaultBaseURL : stored
    }

    func setBaseURL(_ value: String, for kind: AIProviderKind) {
        Defaults.set("aiBaseURL." + kind.rawValue, value.trimmingCharacters(in: .whitespacesAndNewlines))
        objectWillChange.send()
    }

    /// Cached, because a view asks this on every redraw and each answer is a
    /// Keychain call.
    func hasKey(for kind: AIProviderKind) -> Bool {
        if let known = keyPresence[kind.keychainAccount] { return known }
        let found = Keychain.exists(account: kind.keychainAccount)
        keyPresence[kind.keychainAccount] = found
        return found
    }

    /// Read at the moment of the request, never stored.
    ///
    /// Also the one place the presence cache can be corrected: an item removed
    /// in Keychain Access, or an ACL the user denied, would otherwise leave the
    /// app claiming a key is saved for as long as it runs.
    func key(for kind: AIProviderKind) -> String? {
        let value = Keychain.get(account: kind.keychainAccount)
        let present = value != nil
        if keyPresence[kind.keychainAccount] != present {
            keyPresence[kind.keychainAccount] = present
            keyRevision += 1
        }
        return value
    }

    @discardableResult
    func setKey(_ value: String, for kind: AIProviderKind) -> Bool {
        let saved = Keychain.set(value, account: kind.keychainAccount)
        keyPresence[kind.keychainAccount] = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? false
            : saved
        keyRevision += 1
        return saved
    }

    func clearKey(for kind: AIProviderKind) {
        Keychain.remove(account: kind.keychainAccount)
        keyPresence[kind.keychainAccount] = false
        keyRevision += 1
    }

    /// Whether the chosen provider can answer at all right now.
    var aiReady: Bool { return aiProblem == nil }

    /// Why it cannot, in one sentence.
    var aiProblem: String? {
        switch aiProvider {
        case .cursor:
            return cliAvailable ? nil : AgentError.cliNotFound.localizedDescription
        case .anthropic, .openai, .compatible:
            // A local server needs no key, and demanding one would mean
            // inventing a dummy just to talk to Ollama.
            if aiProvider.requiresKey, !hasKey(for: aiProvider) {
                return "No \(aiProvider.keyLabel) is saved. Add it in Settings."
            }
            if model(for: aiProvider).isEmpty {
                return "No model is set for \(aiProvider.label). Pick one in Settings."
            }
            if baseURL(for: aiProvider).isEmpty {
                return "No base URL is set for \(aiProvider.label). Add it in Settings."
            }
            return nil
        }
    }

    /// Reading and writing files in the repository. Resolving a conflict means
    /// writing the merged file, so it needs this.
    var aiCanEditFiles: Bool { return aiProvider.canEditFiles && aiReady }

    @Published var cliAvailable = false
    @Published var cliPathResolved: String?

    /// The workspace owns the window, so it applies the level.
    var onFloatOnTopChange: (() -> Void)?

    var agentSettings: AgentSettings {
        // The CLI key comes out of the Keychain like every other one. It used
        // to sit in UserDefaults, which is the plist this app tells people not
        // to keep secrets in.
        return AgentSettings(binaryPath: cursorBinaryPath,
                             model: cursorModel,
                             apiKey: key(for: .cursor) ?? "")
    }

    init() {
        detectCLI()
        // One Keychain call per provider at launch, so a redraw never makes one.
        for kind in AIProviderKind.allCases {
            keyPresence[kind.keychainAccount] = Keychain.exists(account: kind.keychainAccount)
        }
        // A key left in UserDefaults by an older build moves across, and the
        // plaintext copy goes.
        let legacy = Defaults.string("cursorAPIKey", "")
        if !legacy.isEmpty {
            if Keychain.set(legacy, account: AIProviderKind.cursor.keychainAccount) {
                keyPresence[AIProviderKind.cursor.keychainAccount] = true
            }
            Defaults.set("cursorAPIKey", "")
        }
    }

    func detectCLI() {
        let resolved = CursorAgent.detectBinary(preferred: cursorBinaryPath)
        cliPathResolved = resolved
        cliAvailable = resolved != nil
    }
}
