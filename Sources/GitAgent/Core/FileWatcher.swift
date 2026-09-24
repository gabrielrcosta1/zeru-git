import CoreServices
import Foundation

/// Watches a repository directory with FSEvents and reports coalesced changes.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.burh.gitagent.watcher")
    private let path: String
    private let onChange: () -> Void
    private var debounce: DispatchWorkItem?

    init(root: URL, onChange: @escaping () -> Void) {
        self.path = root.standardizedFileURL.path
        self.onChange = onChange
        start()
    }

    private func start() {
        // The stream owns a strong reference: FSEvents can call back while the
        // owner is releasing us, and an unretained pointer would be a use after free.
        let info = Unmanaged.passRetained(self).toOpaque()
        var context = FSEventStreamContext(version: 0,
                                           info: info,
                                           retain: nil,
                                           release: { pointer in
                                               guard let pointer else { return }
                                               Unmanaged<FileWatcher>.fromOpaque(pointer).release()
                                           },
                                           copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let cPaths = eventPaths.assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self)
            var changed: [String] = []
            for index in 0..<count {
                if let raw = cPaths[index] {
                    changed.append(String(cString: raw))
                }
            }
            watcher.handle(paths: changed)
        }

        guard let stream = FSEventStreamCreate(kCFAllocatorDefault,
                                               callback,
                                               &context,
                                               [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               0.3,
                                               flags) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        debounce?.cancel()
        debounce = nil
    }

    /// Called on the FSEvents queue. All debounce state lives on the main queue.
    private func handle(paths: [String]) {
        guard paths.contains(where: { isRelevant($0) }) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.onChange()
            }
            self.debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    /// Ignores git's internal churn but keeps the events that change repository state.
    private func isRelevant(_ candidate: String) -> Bool {
        if candidate.contains("/.git/") {
            // Lock files come and go around every write. Reacting to them would
            // make the app refresh in the middle of git's own bookkeeping.
            // Scoped to .git, because Cargo.lock and friends are real files.
            if candidate.hasSuffix(".lock") { return false }
            let interesting = ["/.git/HEAD", "/.git/index", "/.git/MERGE_HEAD",
                               "/.git/ORIG_HEAD", "/.git/refs/", "/.git/rebase-merge",
                               "/.git/rebase-apply"]
            for token in interesting where candidate.contains(token) { return true }
            return false
        }
        if candidate.hasSuffix("~") { return false }
        if candidate.contains("/node_modules/") || candidate.contains("/.next/")
            || candidate.contains("/vendor/") || candidate.contains("/.build/")
            || candidate.contains("/dist/") || candidate.contains("/.DS_Store") {
            return false
        }
        return true
    }
}
