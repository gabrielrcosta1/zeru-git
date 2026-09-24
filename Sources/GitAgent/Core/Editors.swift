import AppKit

/// An app that can open a whole project folder.
struct Editor: Identifiable, Hashable {
    /// The bundle identifier, which is also what is remembered as the choice.
    let id: String
    let name: String
    let url: URL
}

enum Editors {

    /// The apps worth offering, in the order they are offered. Only the ones
    /// actually installed on this Mac ever reach the menu, so the list costs
    /// nothing when none of them are here.
    private static let known: [(id: String, name: String)] = [
        ("com.microsoft.VSCode", "Visual Studio Code"),
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("com.exafunction.windsurf", "Windsurf"),
        ("dev.zed.Zed", "Zed"),
        ("com.sublimetext.4", "Sublime Text"),
        ("com.jetbrains.intellij", "IntelliJ IDEA"),
        ("com.jetbrains.intellij.ce", "IntelliJ IDEA CE"),
        ("com.jetbrains.WebStorm", "WebStorm"),
        ("com.jetbrains.PhpStorm", "PhpStorm"),
        ("com.jetbrains.pycharm", "PyCharm"),
        ("com.jetbrains.goland", "GoLand"),
        ("com.apple.dt.Xcode", "Xcode"),
        ("com.googlecode.iterm2", "iTerm"),
        ("com.apple.Terminal", "Terminal")
    ]

    private static var cache: [Editor]?

    /// Which of them are on this Mac. Looked up once: apps are not installed
    /// and uninstalled while a menu is open, and the lookup touches the
    /// Launch Services database.
    static func installed() -> [Editor] {
        if let cache { return cache }
        var found: [Editor] = []
        for entry in known {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.id) else { continue }
            found.append(Editor(id: entry.id, name: entry.name, url: url))
        }
        cache = found
        return found
    }

    /// Forgets the lookup, for when the user installed an editor while the app
    /// was already running.
    static func rescan() {
        cache = nil
    }

    static func editor(withID id: String) -> Editor? {
        return installed().first { $0.id == id }
    }

    /// Opens the folder itself, not a file in it. Returns false when the app
    /// could not be launched at all.
    @MainActor
    static func open(folder: URL, with editor: Editor, completion: @escaping (String?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([folder],
                                withApplicationAt: editor.url,
                                configuration: configuration) { _, error in
            let message = error.map { ($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription }
            Task { @MainActor in completion(message) }
        }
    }
}
