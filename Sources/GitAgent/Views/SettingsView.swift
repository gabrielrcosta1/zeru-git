import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var keyDraft = ""
    @State private var models: [String] = []
    @State private var working = false
    @State private var result: String?
    @State private var resultIsError = false

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (build \(build))"
    }

    private var provider: AIProviderKind { return settings.aiProvider }

    private var modelBinding: Binding<String> {
        return Binding(get: { settings.model(for: settings.aiProvider) },
                       set: { settings.setModel($0, for: settings.aiProvider) })
    }

    private var baseURLBinding: Binding<String> {
        return Binding(get: { settings.baseURL(for: settings.aiProvider) },
                       set: { settings.setBaseURL($0, for: settings.aiProvider) })
    }

    var body: some View {
        Form {
            Section("AI provider") {
                Picker("Answers with", selection: $settings.aiProvider) {
                    ForEach(AIProviderKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.menu)

                Text(provider.hint)
                    .font(Theme.uiTiny)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Image(systemName: settings.aiReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(settings.aiReady ? Theme.added : Theme.removed)
                    Text(settings.aiProblem ?? "Ready")
                        .font(Theme.uiSmall)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }

                if !provider.canEditFiles {
                    Text("Reviews, commit messages and git fix plans work with this provider. Resolving a conflict and fixing a code problem mean writing files, which needs the Cursor CLI \u{2014} those actions stay switched off until you pick it.")
                        .font(Theme.uiTiny)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if provider == .cursor {
                cursorSection
            } else {
                apiSection
            }

            Section("Window") {
                Toggle("Float on top of other apps", isOn: $settings.floatOnTop)
            }

            Section("Git") {
                Toggle("Stage all changes when committing", isOn: $settings.stageAllBeforeCommit)
                Toggle("Resolve pull conflicts with AI", isOn: $settings.resolveConflictsWithAI)
                Text("Git Agent never runs reset --hard, clean, a checkout that discards work, or a force push. Push always asks, and discarding a change always asks first.")
                    .font(Theme.uiTiny)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("When the AI proposes git commands, Git Agent classifies every one of them itself: reading and anything that cannot lose work runs straight through, anything that can stops and shows you the exact command first, and anything off its list never runs. The AI's own opinion of its commands is not used.")
                    .font(Theme.uiTiny)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("About") {
                HStack(spacing: 10) {
                    BrandMark(size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Git Agent")
                            .font(Theme.uiBold)
                        Text(versionText)
                            .font(Theme.uiTiny)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 620)
        .onChange(of: settings.aiProvider) { _ in
            keyDraft = ""
            models = []
            result = nil
        }
    }

    // MARK: Cursor

    @ViewBuilder private var cursorSection: some View {
        Section("Cursor CLI") {
            HStack(spacing: 6) {
                Image(systemName: settings.cliAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(settings.cliAvailable ? Theme.added : Theme.removed)
                if let path = settings.cliPathResolved {
                    Text(path)
                        .font(Theme.codeNumber)
                        .textSelection(.enabled)
                } else {
                    Text("cursor-agent not found in PATH")
                        .font(Theme.uiSmall)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Re-check") { settings.detectCLI() }
            }

            TextField("Binary path (optional)", text: $settings.cursorBinaryPath)
                .font(Theme.code)
            TextField("Model (optional)", text: $settings.cursorModel)
                .font(Theme.code)

            keyRow(for: .cursor)

            Text("Leave the key empty when the CLI is already authenticated with `cursor-agent login`. Install it with `curl https://cursor.com/install -fsS | bash`.")
                .font(Theme.uiTiny)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The API key fields live in the provider's own section, which
            // only appears once the provider is picked. Without this line the
            // Cursor section reads as the only place a key can go.
            Text("To use your own API key instead, change \u{201c}Answers with\u{201d} above to Anthropic, OpenAI or an OpenAI-compatible server \u{2014} the base URL, key and model fields appear there.")
                .font(Theme.uiTiny)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: API providers

    @ViewBuilder private var apiSection: some View {
        Section(provider.label) {
            TextField("Base URL", text: baseURLBinding, prompt: Text(baseURLPrompt))
                .font(Theme.code)

            keyRow(for: provider)

            HStack(spacing: 8) {
                TextField("Model", text: modelBinding, prompt: Text("pick one with Fetch models"))
                    .font(Theme.code)

                if models.isEmpty {
                    Button("Fetch models") { Task { await fetchModels() } }
                        .disabled(working || (provider.requiresKey && !settings.hasKey(for: provider)))
                } else {
                    Menu("\(models.count) models") {
                        ForEach(models, id: \.self) { name in
                            Button(name) { settings.setModel(name, for: provider) }
                        }
                    }
                    .fixedSize()
                }
            }

            HStack(spacing: 8) {
                Button(working ? "Working\u{2026}" : "Test") { Task { await test() } }
                    .disabled(working || (provider.requiresKey && !settings.hasKey(for: provider)))
                if !models.isEmpty {
                    Button("Reload models") { Task { await fetchModels() } }
                        .disabled(working)
                }
                Spacer()
                if working {
                    ProgressView().controlSize(.small)
                }
            }

            if let result {
                Text(result)
                    .font(Theme.uiTiny)
                    .foregroundStyle(resultIsError ? Theme.removed : Theme.added)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The key editor. Reports what actually happened: a Keychain write can
    /// fail, and saying "Saved" when it did not is worse than saying nothing.
    @ViewBuilder private func keyRow(for kind: AIProviderKind) -> some View {
        HStack(spacing: 6) {
            Image(systemName: settings.hasKey(for: kind) ? "lock.fill" : "lock.open")
                .foregroundStyle(settings.hasKey(for: kind) ? Theme.added : Color.secondary)
            Text(settings.hasKey(for: kind)
                 ? "A key is saved in your Keychain"
                 : (kind.requiresKey ? "No key saved" : "No key saved \u{2014} not required"))
                .font(Theme.uiSmall)
                .foregroundStyle(.secondary)
            Spacer()
            if settings.hasKey(for: kind) {
                Button("Remove") {
                    settings.clearKey(for: kind)
                    keyDraft = ""
                    models = []
                    result = nil
                }
            }
        }

        HStack(spacing: 8) {
            SecureField(kind.keyLabel, text: $keyDraft)
                .font(Theme.code)
            Button("Save") {
                if settings.setKey(keyDraft, for: kind) {
                    result = "Saved to your Keychain."
                    resultIsError = false
                } else {
                    result = "The Keychain refused to store it. Check Keychain Access, then try again."
                    resultIsError = true
                }
                keyDraft = ""
            }
            .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        Text("The key goes into your login Keychain, never into the app's preferences, and it is read only at the moment of a request.")
            .font(Theme.uiTiny)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var baseURLPrompt: String {
        switch provider {
        case .compatible: return "https://openrouter.ai/api/v1"
        default: return provider.defaultBaseURL
        }
    }

    // MARK: Actions

    private func engine() -> HTTPEngine? {
        // A local server needs no key, so an absent one is only fatal when the
        // provider actually requires it.
        let key = settings.key(for: provider)
        if provider.requiresKey, key == nil { return nil }
        return HTTPEngine(kind: provider,
                          model: settings.model(for: provider),
                          baseURL: settings.baseURL(for: provider),
                          key: key ?? "")
    }

    @MainActor private func fetchModels() async {
        guard let engine = engine() else {
            result = "Save a key first."
            resultIsError = true
            return
        }
        working = true
        result = nil
        do {
            let found = try await engine.models()
            models = found
            result = found.isEmpty ? "That key reached no models." : "\(found.count) models available."
            resultIsError = found.isEmpty
        } catch {
            models = []
            result = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            resultIsError = true
        }
        working = false
    }

    @MainActor private func test() async {
        guard let engine = engine() else {
            result = "Save a key first."
            resultIsError = true
            return
        }
        working = true
        result = nil
        do {
            let answer = try await engine.run(prompt: "Reply with the single word: ok", onEvent: { _ in })
            let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
            result = "Answered: " + String(text.prefix(120))
            resultIsError = false
        } catch {
            result = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            resultIsError = true
        }
        working = false
    }
}

/// The settings window, owned by this app.
///
/// It used to be SwiftUI's `Settings` scene, opened by sending
/// `showSettingsWindow:` down the responder chain. That selector is private,
/// it was renamed once already, and when it does nothing there is no error
/// and no window: the user presses the menu item and the app just sits there.
/// An NSWindow this app holds itself always opens.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    private var window: NSWindow?

    func show(settings: AppSettings) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView().environmentObject(settings))
        let created = NSWindow(contentViewController: hosting)
        created.title = "Git Agent Settings"
        created.styleMask = [.titled, .closable]
        // The main window floats when the user asked it to, and a normal-level
        // window opens underneath a floating one.
        created.level = settings.floatOnTop ? .floating : .normal
        // Closing it must not deallocate it: this reference outlives the close,
        // and the same window is shown again on the next open.
        created.isReleasedWhenClosed = false
        created.center()
        window = created
        created.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Follows the main window: toggling "Float on Top" from inside this window
    /// would otherwise push the main one in front of it.
    func setLevel(floating: Bool) {
        window?.level = floating ? .floating : .normal
    }
}
