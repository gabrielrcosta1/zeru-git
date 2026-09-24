import Foundation

// MARK: - Result

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { return status == 0 }
}

enum ShellError: LocalizedError {
    case notFound(String)
    case failed(command: String, status: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .notFound(let bin):
            return "Executable not found: \(bin)"
        case .failed(let command, let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "\(command) exited with status \(status)"
            }
            return "\(command): \(detail)"
        }
    }
}

enum ShellEvent {
    case stdout(String)
    case stderr(String)
    case exit(Int32)
}

// MARK: - Line buffer

/// Splits a byte stream into lines. Thread safe.
final class LineBuffer {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        var lines: [String] = []
        while let index = data.firstIndex(of: 0x0A) {
            let lineData = Data(data[data.startIndex..<index])
            data = Data(data[data.index(after: index)...])
            lines.append(String(utf8Lossy: lineData))
        }
        return lines
    }

    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !data.isEmpty else { return nil }
        let remainder = String(utf8Lossy: data)
        data = Data()
        return remainder
    }
}

extension String {
    init(utf8Lossy data: Data) {
        if let value = String(data: data, encoding: .utf8) {
            self = value
        } else {
            self = String(decoding: data, as: UTF8.self)
        }
    }
}

// MARK: - Shell

enum Shell {

    static let extraSearchPaths: [String] = {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            home + "/.local/bin",
            home + "/.cursor/bin",
            home + "/bin"
        ]
    }()

    /// Resolves an executable name (or absolute path) to a usable path.
    static func which(_ name: String) -> String? {
        let fm = FileManager.default
        if name.contains("/") {
            let expanded = (name as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        var candidates = extraSearchPaths
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        for directory in candidates where !directory.isEmpty {
            let candidate = directory.hasSuffix("/") ? directory + name : directory + "/" + name
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func environment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var parts = extraSearchPaths
        if let path = env["PATH"] {
            parts.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        var seen = Set<String>()
        env["PATH"] = parts.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        // A rebase --continue would otherwise sit waiting on an editor forever.
        env["GIT_EDITOR"] = "true"
        env["GIT_SEQUENCE_EDITOR"] = "true"
        for (key, value) in extra { env[key] = value }
        return env
    }

    /// Runs a command to completion and collects its output.
    static func run(_ executable: String,
                    _ arguments: [String],
                    cwd: URL?,
                    extraEnv: [String: String] = [:],
                    timeout: TimeInterval? = nil) async throws -> CommandResult {
        guard let binary = which(executable) else { throw ShellError.notFound(executable) }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = arguments
                process.environment = environment(extra: extraEnv)
                if let cwd { process.currentDirectoryURL = cwd }

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = FileHandle.nullDevice

                let outBox = DataBox()
                let errBox = DataBox()
                let group = DispatchGroup()

                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    outBox.value = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errBox.value = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                ProcessRegistry.shared.add(process.processIdentifier)
                defer { ProcessRegistry.shared.remove(process.processIdentifier) }

                let watchdog = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                if let timeout {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout,
                                                                   execute: watchdog)
                }
                process.waitUntilExit()
                watchdog.cancel()
                let status = process.terminationStatus

                // A killed git can leave children (ssh, a credential helper)
                // holding the pipe write ends, so the reads may never reach EOF.
                guard group.wait(timeout: .now() + 2) == .success else {
                    continuation.resume(returning: CommandResult(status: status, stdout: "", stderr: ""))
                    return
                }
                continuation.resume(returning: CommandResult(
                    status: status,
                    stdout: String(utf8Lossy: outBox.value),
                    stderr: String(utf8Lossy: errBox.value)
                ))
            }
        }
    }

    /// Streams stdout/stderr lines while the command runs.
    static func stream(_ executable: String,
                       _ arguments: [String],
                       cwd: URL?,
                       extraEnv: [String: String] = [:],
                       onStart: ((Process) -> Void)? = nil) -> AsyncThrowingStream<ShellEvent, Error> {
        return AsyncThrowingStream { continuation in
            guard let binary = which(executable) else {
                continuation.finish(throwing: ShellError.notFound(executable))
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            process.environment = environment(extra: extraEnv)
            if let cwd { process.currentDirectoryURL = cwd }

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = FileHandle.nullDevice

            let outBuffer = LineBuffer()
            let errBuffer = LineBuffer()
            // Every mutation and every yield happens on this queue, so reads cannot
            // interleave with the final drain.
            let sync = DispatchQueue(label: "com.burh.gitagent.shell.stream")
            let openPipes = Counter(2)

            func drainAndFinish() {
                if let tail = outBuffer.flush(), !tail.isEmpty { continuation.yield(.stdout(tail)) }
                if let tail = errBuffer.flush(), !tail.isEmpty { continuation.yield(.stderr(tail)) }
                process.waitUntilExit()
                ProcessRegistry.shared.remove(process.processIdentifier)
                continuation.yield(.exit(process.terminationStatus))
                continuation.finish()
            }

            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
                ProcessRegistry.shared.remove(process.processIdentifier)
            }

            onStart?(process)
            do {
                try process.run()
                ProcessRegistry.shared.add(process.processIdentifier)
            } catch {
                continuation.finish(throwing: error)
                return
            }

            // Installed after the launch, so the pid is registered before any
            // handler can report EOF and unregister it again.
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                sync.async {
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        if openPipes.decrement() == 0 { drainAndFinish() }
                        return
                    }
                    for line in outBuffer.append(chunk) { continuation.yield(.stdout(line)) }
                }
            }

            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                sync.async {
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        if openPipes.decrement() == 0 { drainAndFinish() }
                        return
                    }
                    for line in errBuffer.append(chunk) { continuation.yield(.stderr(line)) }
                }
            }
        }
    }
}

/// Every git process the app starts, so a lock held by our own command (or by a
/// hook it started) can be told apart from one held by another app.
final class ProcessRegistry {
    static let shared = ProcessRegistry()

    private var pids = Set<Int32>()
    private let lock = NSLock()

    func add(_ pid: Int32) {
        lock.lock()
        pids.insert(pid)
        lock.unlock()
    }

    func remove(_ pid: Int32) {
        lock.lock()
        pids.remove(pid)
        lock.unlock()
    }

    func contains(_ pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pids.contains(pid)
    }
}

/// Reference box so background reads can publish their data.
final class DataBox {
    var value = Data()
}

/// Small thread safe countdown used to detect that both pipes reached EOF.
final class Counter {
    private var value: Int
    private let lock = NSLock()

    init(_ value: Int) { self.value = value }

    func decrement() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value -= 1
        return value
    }
}
