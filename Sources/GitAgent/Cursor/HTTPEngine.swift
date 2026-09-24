import Foundation

// MARK: - Which provider

enum AIProviderKind: String, CaseIterable, Hashable, Identifiable {
    case cursor
    case anthropic
    case openai
    case compatible

    var id: String { return rawValue }

    var label: String {
        switch self {
        case .cursor: return "Cursor CLI"
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .compatible: return "OpenAI-compatible"
        }
    }

    /// Reads and writes files in the repository. Only the CLI does: an API
    /// answers with text, so resolving a conflict — which means writing the
    /// merged file — is not something it can do on its own.
    var canEditFiles: Bool {
        switch self {
        case .cursor: return true
        case .anthropic, .openai, .compatible: return false
        }
    }

    var needsKey: Bool { return self != .cursor }

    /// Whether a key is required to talk at all. A local server \u{2014} Ollama,
    /// LM Studio \u{2014} wants none, and making the user invent one would be
    /// theatre.
    var requiresKey: Bool {
        switch self {
        case .cursor, .compatible: return false
        case .anthropic, .openai: return true
        }
    }

    /// The API shape, for the two that are not the CLI.
    var isAnthropicShape: Bool { return self == .anthropic }

    var defaultBaseURL: String {
        switch self {
        case .cursor: return ""
        case .anthropic: return "https://api.anthropic.com"
        case .openai: return "https://api.openai.com/v1"
        case .compatible: return ""
        }
    }

    /// One item in the Keychain per provider.
    var keychainAccount: String { return "apiKey." + rawValue }

    var keyLabel: String {
        switch self {
        case .cursor: return "CURSOR_API_KEY"
        case .anthropic: return "Anthropic API key"
        case .openai: return "OpenAI API key"
        case .compatible: return "API key"
        }
    }

    var hint: String {
        switch self {
        case .cursor:
            return "Uses the cursor-agent CLI you already signed in to. It is the only provider that can read and write files, so AI conflict resolution and Fix with AI on a code problem need it."
        case .anthropic:
            return "Talks to the Anthropic Messages API with your own key. Reviews, commit messages and git fix plans work; writing files does not."
        case .openai:
            return "Talks to the OpenAI Chat Completions API with your own key. Reviews, commit messages and git fix plans work; writing files does not."
        case .compatible:
            return "Anything that speaks the OpenAI Chat Completions shape: OpenRouter, Groq, DeepSeek, Together, Ollama or LM Studio on this Mac. Give the base URL that ends in /v1."
        }
    }
}

// MARK: - The engine

/// One request to a chat API, and back.
///
/// No tools, no shell, no file access: these providers answer with text, and
/// everything the app asks of them — a review, a commit message, a plan of git
/// commands — is text. The key is passed in for one request and never stored
/// on this object beyond it.
final class HTTPEngine {

    private let kind: AIProviderKind
    private let model: String
    private let baseURL: String
    private let key: String
    private let session: URLSession

    init(kind: AIProviderKind, model: String, baseURL: String, key: String) {
        self.kind = kind
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = HTTPEngine.normalize(baseURL)
        self.key = key
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
    }

    /// A request in flight is stopped by tearing the session down; this engine
    /// is built for one run, so it is never reused afterwards.
    func cancel() {
        session.invalidateAndCancel()
    }

    /// A URLSession that is never invalidated is never released, along with its
    /// connection pool. Every run ends here, success included.
    private func finish() {
        session.finishTasksAndInvalidate()
    }

    /// Both spellings of a base URL work: "https://api.anthropic.com" and
    /// "https://api.anthropic.com/v1" reach the same endpoint, instead of one
    /// of them becoming /v1/v1/messages and a 404 blamed on the model name.
    private func endpoint(_ tail: String) -> URL? {
        // An empty base would build "/v1/messages", which URL(string:) happily
        // accepts as a relative URL.
        guard !baseURL.isEmpty else { return nil }
        let versioned = baseURL.hasSuffix("/v1")
        let path = versioned ? tail : "/v1" + tail
        return URL(string: baseURL + path)
    }

    /// Trims the trailing slash and refuses anything that is not http(s).
    /// `URL(string:)` accepts a scheme-less string as a relative URL, so
    /// checking for nil is not a check at all.
    private static func normalize(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text = String(text.dropLast()) }
        let lower = text.lowercased()
        guard lower.hasPrefix("https://") || lower.hasPrefix("http://") else { return "" }
        return text
    }

    // MARK: Running a prompt

    func run(prompt: String, onEvent: @escaping (AgentEvent) -> Void) async throws -> AgentRunResult {
        if kind.requiresKey, key.isEmpty {
            throw AgentError.failed("No API key is saved for \(kind.label).")
        }
        guard !model.isEmpty else {
            throw AgentError.failed("No model is set for \(kind.label). Pick one in Settings.")
        }
        guard let url = endpoint(kind.isAnthropicShape ? "/messages" : "/chat/completions") else {
            // The URL is not echoed: a base URL pasted with a token in its
            // query string would end up in the activity log.
            throw AgentError.failed("The base URL for \(kind.label) is not a valid http(s) URL.")
        }
        defer { finish() }

        onEvent(.started(model: model, sessionID: ""))

        // Anthropic requires max_tokens, and several models cap it below 8192
        // and reject the request outright rather than clamping. One retry
        // rather than a table of caps to keep up to date.
        var limit = 8192
        var data = Data()
        while true {
            let request = buildRequest(url: url, prompt: prompt, maxTokens: limit)
            let pair: (Data, URLResponse)
            do {
                pair = try await session.data(for: request)
            } catch let error as URLError where error.code == .cancelled {
                throw AgentError.cancelled
            } catch {
                throw AgentError.failed(HTTPEngine.transportMessage(error))
            }
            data = pair.0
            guard let http = pair.1 as? HTTPURLResponse else { break }
            if (200...299).contains(http.statusCode) { break }

            let problem = message(forStatus: http.statusCode, data: data)
            if limit > 4096, problem.lowercased().contains("max_tokens") {
                limit = 4096
                continue
            }
            throw AgentError.failed(problem)
        }

        let text = try extractText(from: data)
        onEvent(.assistantText(text))
        return AgentRunResult(text: text,
                              isError: false,
                              sessionID: nil,
                              touchedFiles: [],
                              toolCalls: 0)
    }

    private func buildRequest(url: URL, prompt: String, maxTokens: Int) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]]
        ]
        if kind.isAnthropicShape {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body["max_tokens"] = maxTokens
        } else if !key.isEmpty {
            // No max_tokens on this shape: it is optional, and the reasoning
            // models reject it in favour of max_completion_tokens.
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: Listing models

    /// What this key can actually reach. Beats guessing a model name that was
    /// retired, which is the usual reason a first request fails.
    func models() async throws -> [String] {
        if kind.requiresKey, key.isEmpty {
            throw AgentError.failed("No API key is saved for \(kind.label).")
        }
        guard let url = endpoint(kind.isAnthropicShape ? "/models?limit=100" : "/models") else {
            throw AgentError.failed("The base URL for \(kind.label) is not a valid http(s) URL.")
        }
        defer { finish() }
        var request = URLRequest(url: url)
        if kind.isAnthropicShape {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !key.isEmpty {
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }

        let pair: (Data, URLResponse)
        do {
            pair = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw AgentError.cancelled
        } catch {
            throw AgentError.failed(HTTPEngine.transportMessage(error))
        }
        let data = pair.0
        if let http = pair.1 as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AgentError.failed(message(forStatus: http.statusCode, data: data))
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else {
            throw AgentError.failed("\(kind.label) answered with a model list this app cannot read.")
        }
        // Embeddings, speech and image models cannot answer a chat request, and
        // offering them in the picker only invites a confusing failure.
        let unusable = ["embedding", "whisper", "tts", "dall-e", "moderation",
                        "audio", "image", "rerank", "davinci", "babbage"]
        let names = list.compactMap { $0["id"] as? String }
            .filter { name in
                let lower = name.lowercased()
                return !unusable.contains { lower.contains($0) }
            }
        return names.sorted()
    }

    // MARK: Reading the answer

    private func extractText(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError.failed("\(kind.label) answered with something that is not JSON.")
        }

        // The app parses JSON out of these answers. A truncated one never
        // closes its braces, and "the model answered without structured JSON"
        // would send the user looking in entirely the wrong place.
        if HTTPEngine.wasTruncated(object) {
            throw AgentError.failed("\(kind.label) ran out of output room before finishing the answer. A model with a larger output limit, or fewer changes at once, will get through it.")
        }

        if kind.isAnthropicShape {
            // content is a list of blocks; the text ones are the answer.
            if let blocks = object["content"] as? [[String: Any]] {
                let text = blocks.compactMap { block -> String? in
                    guard (block["type"] as? String) == "text" else { return nil }
                    return block["text"] as? String
                }.joined()
                if !text.isEmpty { return text }
            }
        } else {
            if let choices = object["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let text = message["content"] as? String, !text.isEmpty {
                return text
            }
            // Some compatible servers answer in the completion shape instead.
            if let choices = object["choices"] as? [[String: Any]],
               let text = choices.first?["text"] as? String, !text.isEmpty {
                return text
            }
        }

        if let problem = HTTPEngine.errorMessage(in: object) {
            throw AgentError.failed(problem)
        }
        throw AgentError.failed("\(kind.label) answered without any text in it.")
    }

    private func message(forStatus status: Int, data: Data) -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let detail = object.flatMap { HTTPEngine.errorMessage(in: $0) }

        switch status {
        case 401, 403:
            return detail ?? "\(kind.label) rejected the API key. Check it in Settings."
        case 404:
            return detail ?? "\(kind.label) does not have a model called \"\(model)\". Use Fetch models in Settings."
        case 429:
            return detail ?? "\(kind.label) is rate limiting this key. Try again in a moment."
        case 500...599:
            return detail ?? "\(kind.label) had a server error (\(status))."
        default:
            return detail ?? "\(kind.label) refused the request (\(status))."
        }
    }

    /// Both shapes put the reason in "error", one as an object and one as a
    /// string, and some compatible servers use "message" at the top.
    private static func errorMessage(in object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        if let error = object["error"] as? String, !error.isEmpty { return error }
        if let message = object["message"] as? String, !message.isEmpty { return message }
        return nil
    }

    /// Anthropic says stop_reason, the chat shape says finish_reason.
    private static func wasTruncated(_ object: [String: Any]) -> Bool {
        if let reason = object["stop_reason"] as? String, reason == "max_tokens" { return true }
        if let choices = object["choices"] as? [[String: Any]],
           let reason = choices.first?["finish_reason"] as? String, reason == "length" {
            return true
        }
        return false
    }

    private static func transportMessage(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "No network connection."
        case .cannotFindHost, .cannotConnectToHost:
            return "Could not reach that host. Check the base URL."
        case .timedOut:
            return "The request timed out."
        case .secureConnectionFailed, .serverCertificateUntrusted:
            return "The secure connection failed."
        default:
            return urlError.localizedDescription
        }
    }
}
