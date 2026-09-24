import AppKit
import Combine
import Foundation

/// Compact panel, or wide enough for the detail panel next to it.
enum WindowMode {
    case compact
    case expanded

    /// The one source of truth for both widths. Lives here, outside the
    /// main-actor types, so nonisolated code can read it.
    static let compactWidth: CGFloat = 396
    static let expandedWidth: CGFloat = 940

    var key: String {
        switch self {
        case .compact: return "compactWindowWidth"
        case .expanded: return "expandedWindowWidth"
        }
    }

    var defaultWidth: Int {
        switch self {
        case .compact: return Int(WindowMode.compactWidth)
        case .expanded: return Int(WindowMode.expandedWidth)
        }
    }
}

/// Owns the open projects. Each tab is a full, independent session: its own
/// repository, watcher, agent, review, commit message and detail panel.
@MainActor
final class Workspace: ObservableObject {

    @Published private(set) var tabs: [ProjectSession] = []
    @Published var activeID: UUID?
    @Published var recentProjects: [String] = Defaults.array("recentProjects")
    @Published var openError: String?
    /// The search palette, over whichever project is in front.
    @Published var paletteOpen = false

    let settings = AppSettings()
    weak var window: NSWindow?

    private var observers: [UUID: AnyCancellable] = [:]
    private var appliedMode: WindowMode?
    private var resizeObserver: NSObjectProtocol?
    private var liveResizeObserver: NSObjectProtocol?
    private var applyingWidth = false
    private var activationObserver: NSObjectProtocol?

    var active: ProjectSession? {
        guard let activeID else { return nil }
        return tabs.first { $0.id == activeID }
    }

    var hasTabs: Bool { return !tabs.isEmpty }

    init() {
        settings.onFloatOnTopChange = { [weak self] in
            self?.applyWindowLevel()
        }
        AppActions.settings = settings
        observeActivation()
    }

    /// Coming back to the app is exactly when the remote has moved: a PR was
    /// merged in the browser and the counters here are from before it. Fetching
    /// on activation is what makes the pull button appear without pressing
    /// refresh.
    private func observeActivation() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                Task { @MainActor in
                    // An editor installed while this app was running should
                    // show up in the Open in menu without a restart.
                    Editors.rescan()
                    await self?.active?.fetchIfStale()
                }
            }
    }

    // MARK: - Opening

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose one or more git repositories"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            for url in urls { await open(url: url) }
        }
    }

    func open(url: URL, silentFailure: Bool = false, activate: Bool = true) async {
        openError = nil

        guard FileManager.default.fileExists(atPath: url.path) else {
            if !silentFailure { openError = "\(url.path) no longer exists." }
            forget(url.path)
            return
        }

        guard let root = await GitRepository.discoverRoot(from: url) else {
            if !silentFailure {
                openError = "\(url.lastPathComponent) is not a git repository (no .git found)."
            }
            return
        }

        // Already open: just bring it forward.
        if let existing = tabs.first(where: { $0.root.standardizedFileURL == root.standardizedFileURL }) {
            if activate { activeID = existing.id }
            persistTabs()
            applyWindowWidth()
            return
        }

        let session = ProjectSession(root: root, settings: settings)
        session.workspace = self
        observe(session)
        tabs.append(session)
        if activate || activeID == nil { activeID = session.id }
        remember(root.path)
        persistTabs()
        applyWindowWidth()
        // start() ends in a git fetch: never make the next tab wait for it.
        Task { await session.start() }
    }

    /// Reopens the tabs that were open last time.
    func restore() async {
        let saved = Defaults.array("openProjects")
        let previouslyActive = Defaults.string("activeProject", "")
        guard !saved.isEmpty else { return }
        for path in saved {
            await open(url: URL(fileURLWithPath: path, isDirectory: true),
                       silentFailure: true,
                       activate: path == previouslyActive)
        }
        if active == nil { activeID = tabs.first?.id }
        persistTabs()
        applyWindowWidth()
    }

    // MARK: - Closing and switching

    func close(_ session: ProjectSession) {
        // The palette belongs to whatever is in front, and that is changing.
        paletteOpen = false
        session.teardown()
        observers[session.id] = nil

        let index = tabs.firstIndex { $0.id == session.id }
        tabs.removeAll { $0.id == session.id }

        if activeID == session.id {
            if let index {
                let neighbour = min(index, tabs.count - 1)
                activeID = tabs.indices.contains(neighbour) ? tabs[neighbour].id : nil
            } else {
                activeID = tabs.first?.id
            }
        }
        persistTabs()
        applyWindowWidth()
    }

    func closeActive() {
        guard let active else { return }
        close(active)
    }

    func select(_ session: ProjectSession) {
        guard activeID != session.id else { return }
        // Stashes, Activity and All changes are views of whatever project is in
        // front, so they follow the switch instead of collapsing the window.
        // A panel the other tab opened itself is left as it is.
        let carried = active?.detail
        activeID = session.id
        if let carried { session.adopt(panel: carried) }
        persistTabs()
        applyWindowWidth()
        Task {
            await session.refresh(silent: true)
            await session.fetchIfStale()
        }
    }

    func selectNext(_ offset: Int) {
        guard tabs.count > 1, let activeID,
              let index = tabs.firstIndex(where: { $0.id == activeID }) else { return }
        let next = (index + offset + tabs.count) % tabs.count
        select(tabs[next])
    }

    // MARK: - Window

    func adopt(_ window: NSWindow) {
        let isNew = self.window !== window
        self.window = window
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        applyWindowLevel()
        if isNew {
            observeResizes(window)
            appliedMode = nil
            applyWindowWidth()
        }
    }

    /// The width the user drags the window to is the width they want. Remember
    /// it per mode instead of overriding it on the next action.
    private func observeResizes(_ window: NSWindow) {
        for token in [resizeObserver, liveResizeObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(token)
        }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: window,
            queue: .main) { [weak self] _ in
                Task { @MainActor in self?.rememberWidth() }
            }
        // Zooming with the green button, or a resize from a menu command, never
        // sends didEndLiveResize.
        liveResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main) { [weak self] notification in
                guard let resized = notification.object as? NSWindow, !resized.inLiveResize else { return }
                Task { @MainActor in self?.rememberWidth() }
            }
    }

    private func rememberWidth() {
        guard let window, !applyingWidth else { return }
        let width = Int(window.frame.width.rounded())
        guard width > 300 else { return }
        let mode = currentMode
        Defaults.set(mode.key, width)
        appliedMode = mode
    }

    private var currentMode: WindowMode {
        return active?.detail == nil ? .compact : .expanded
    }

    private func storedWidth(for mode: WindowMode) -> CGFloat {
        let value = Defaults.int(mode.key, mode.defaultWidth)
        return CGFloat(min(max(value, 360), 2400))
    }

    func applyWindowLevel() {
        window?.level = settings.floatOnTop ? .floating : .normal
        SettingsWindow.shared.setLevel(floating: settings.floatOnTop)
    }

    /// Compact by default, wider only while the active tab has a panel open.
    /// Only ever fires when the mode actually changes: resizing the window by
    /// hand must stick.
    func applyWindowWidth() {
        let mode = currentMode
        guard mode != appliedMode else { return }
        appliedMode = mode
        let target = storedWidth(for: mode)
        Task { @MainActor [weak self] in
            guard let self, let window = self.window else { return }
            var frame = window.frame
            guard abs(frame.size.width - target) > 1 else { return }
            frame.size.width = target
            if let screen = window.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                if frame.maxX > visible.maxX {
                    frame.origin.x = max(visible.minX, visible.maxX - target)
                }
            }
            self.applyingWidth = true
            window.setFrame(frame, display: true, animate: true)
            self.applyingWidth = false
        }
    }

    // MARK: - Plumbing

    /// A change inside any tab redraws the window: the tab bar shows live
    /// counters for the projects that are not in front.
    private func observe(_ session: ProjectSession) {
        observers[session.id] = session.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    private func remember(_ path: String) {
        var list = recentProjects.filter { $0 != path }
        list.insert(path, at: 0)
        if list.count > 10 { list = Array(list.prefix(10)) }
        recentProjects = list
        Defaults.set("recentProjects", list)
    }

    private func forget(_ path: String) {
        recentProjects = recentProjects.filter { $0 != path }
        Defaults.set("recentProjects", recentProjects)
    }

    private func persistTabs() {
        Defaults.set("openProjects", tabs.map { $0.root.path })
        Defaults.set("activeProject", active?.root.path ?? "")
    }
}
