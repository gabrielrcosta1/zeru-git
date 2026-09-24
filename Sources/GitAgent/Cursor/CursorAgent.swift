import Foundation

// MARK: - Events

enum AgentEvent {
    case started(model: String, sessionID: String)
    case assistantText(String)
    case tool(name: String, detail: String, finished: Bool)
    case log(String)
}

struct AgentRunResult {
    var text: String
    var isError: Bool
    var sessionID: String?
    var touchedFiles: [String]
    var toolCalls: Int
}

struct AgentSettings {
    var binaryPath: String = ""
    var model: String = ""
    var apiKey: String = ""
}

enum AgentError: LocalizedError {
    case cliNotFound
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "Cursor CLI not found. Install it with `curl https://cursor.com/install -fsS | bash`, run `cursor-agent login`, or set the binary path in Settings."
        case .failed(let message):
            return message.isEmpty ? "The Cursor agent failed." : message
        case .cancelled:
            return "Cancelled."
        }
    }
}

// MARK: - Agent

/// Wraps the official Cursor CLI (`cursor-agent`) in non interactive mode.
/// Reference: cursor.com/docs/cli - `-p/--print`, `--output-format stream-json`.
final class CursorAgent {

    private let lock = NSLock()
    private var current: Process?

    static let candidateNames = ["cursor-agent", "agent"]

    /// Resolves the CLI binary, honouring an explicit path from Settings first.
    static func detectBinary(preferred: String) -> String? {
        let trimmed = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let resolved = Shell.which(trimmed) { return resolved }
        for name in candidateNames {
            if let resolved = Shell.which(name) { return resolved }
        }
        return nil
    }

    /// Synchronous so the lock is never taken from an async context
    /// (NSLock.lock is unavailable there in Swift 6).
    private func setCurrent(_ process: Process?) {
        lock.lock()
        current = process
        lock.unlock()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return current?.isRunning ?? false
    }

    func cancel() {
        lock.lock()
        let process = current
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    // MARK: Run

    func run(prompt: String,
             workspace: URL,
             settings: AgentSettings,
             onEvent: @escaping (AgentEvent) -> Void) async throws -> AgentRunResult {

        guard let binary = CursorAgent.detectBinary(preferred: settings.binaryPath) else {
            throw AgentError.cliNotFound
        }

        var attempts: [[String]] = []
        attempts.append(arguments(prompt: prompt, workspace: workspace, settings: settings, includeTrust: true, includeWorkspace: true))
        attempts.append(arguments(prompt: prompt, workspace: workspace, settings: settings, includeTrust: false, includeWorkspace: true))
        attempts.append(arguments(prompt: prompt, workspace: workspace, settings: settings, includeTrust: false, includeWorkspace: false))

        var lastError = ""
        for (index, argumentList) in attempts.enumerated() {
            do {
                return try await execute(binary: binary,
                                        arguments: argumentList,
                                        workspace: workspace,
                                        settings: settings,
                                        onEvent: onEvent)
            } catch AgentError.failed(let message) {
                lastError = message
                let lower = message.lowercased()
                let looksLikeBadFlag = lower.contains("unknown option")
                    || lower.contains("unknown argument")
                    || lower.contains("unrecognized")
                    || lower.contains("usage:")
                if looksLikeBadFlag && index < attempts.count - 1 {
                    onEvent(.log("retrying without unsupported flags"))
                    continue
                }
                throw AgentError.failed(message)
            }
        }
        throw AgentError.failed(lastError)
    }

    private func arguments(prompt: String,
                           workspace: URL,
                           settings: AgentSettings,
                           includeTrust: Bool,
                           includeWorkspace: Bool) -> [String] {
        var arguments = ["-p", prompt, "--output-format", "stream-json", "--force"]
        if includeTrust { arguments.append("--trust") }
        if includeWorkspace { arguments.append(contentsOf: ["--workspace", workspace.path]) }
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { arguments.append(contentsOf: ["--model", model]) }
        return arguments
    }

    private func execute(binary: String,
                         arguments: [String],
                         workspace: URL,
                         settings: AgentSettings,
                         onEvent: @escaping (AgentEvent) -> Void) async throws -> AgentRunResult {

        var extraEnv: [String: String] = [:]
        let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { extraEnv["CURSOR_API_KEY"] = key }

        var assistantText = ""
        var resultText: String?
        var isError = false
        var sessionID: String?
        var touched: [String] = []
        var toolCalls = 0
        var stderrLines: [String] = []
        var status: Int32 = 0

        let stream = Shell.stream(binary, arguments, cwd: workspace, extraEnv: extraEnv) { [weak self] process in
            self?.setCurrent(process)
        }
        defer { setCurrent(nil) }

        for try await event in stream {
            switch event {
            case .stdout(let line):
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard let data = trimmed.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    onEvent(.log(trimmed))
                    continue
                }
                switch object["type"] as? String {
                case "system":
                    sessionID = object["session_id"] as? String
                    onEvent(.started(model: (object["model"] as? String) ?? "default",
                                     sessionID: sessionID ?? ""))
                case "assistant":
                    let text = CursorAgent.text(fromMessage: object["message"])
                    if !text.isEmpty {
                        assistantText += (assistantText.isEmpty ? "" : "\n") + text
                        onEvent(.assistantText(text))
                    }
                case "tool_call":
                    let finished = (object["subtype"] as? String) == "completed"
                    let info = CursorAgent.describeTool(object["tool_call"])
                    if !finished { toolCalls += 1 }
                    if finished, let path = info.path, CursorAgent.isMutating(info.name) {
                        if !touched.contains(path) { touched.append(path) }
                    }
                    onEvent(.tool(name: info.name, detail: info.detail, finished: finished))
                case "result":
                    resultText = object["result"] as? String
                    isError = (object["is_error"] as? Bool) ?? false
                    if sessionID == nil { sessionID = object["session_id"] as? String }
                default:
                    continue
                }
            case .stderr(let line):
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    stderrLines.append(trimmed)
                    onEvent(.log(trimmed))
                }
            case .exit(let code):
                status = code
            }
        }

        let finalText = (resultText?.isEmpty == false ? resultText! : assistantText)

        if status != 0 && finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let message = stderrLines.suffix(6).joined(separator: "\n")
            throw AgentError.failed(message.isEmpty ? "cursor-agent exited with status \(status)" : message)
        }

        return AgentRunResult(text: finalText,
                              isError: isError || status != 0,
                              sessionID: sessionID,
                              touchedFiles: touched,
                              toolCalls: toolCalls)
    }

    // MARK: Stream helpers

    private static func text(fromMessage message: Any?) -> String {
        guard let message = message as? [String: Any] else { return "" }
        if let text = message["text"] as? String { return text }
        guard let content = message["content"] as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for block in content {
            if let text = block["text"] as? String, !text.isEmpty { parts.append(text) }
        }
        return parts.joined()
    }

    private static func describeTool(_ raw: Any?) -> (name: String, detail: String, path: String?) {
        guard let dictionary = raw as? [String: Any], let key = dictionary.keys.first else {
            return ("tool", "", nil)
        }
        let name = friendlyName(key)
        var detail = ""
        var path: String?
        if let payload = dictionary[key] as? [String: Any],
           let args = payload["args"] as? [String: Any] {
            for candidate in ["path", "file_path", "target_file", "relative_workspace_path", "filePath"] {
                if let value = args[candidate] as? String, !value.isEmpty {
                    path = value
                    detail = value
                    break
                }
            }
            if detail.isEmpty {
                for candidate in ["command", "query", "pattern", "prompt"] {
                    if let value = args[candidate] as? String, !value.isEmpty {
                        detail = value
                        break
                    }
                }
            }
        }
        return (name, detail, path)
    }

    private static func friendlyName(_ key: String) -> String {
        var name = key
        if name.hasSuffix("ToolCall") { name = String(name.dropLast("ToolCall".count)) }
        var output = ""
        for character in name {
            if character.isUppercase && !output.isEmpty { output.append(" ") }
            output += character.lowercased()
        }
        return output.isEmpty ? "tool" : output
    }

    private static func isMutating(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("write") || lower.contains("edit") || lower.contains("create")
            || lower.contains("delete") || lower.contains("patch") || lower.contains("search replace")
    }
}
