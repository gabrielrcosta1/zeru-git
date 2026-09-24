import Foundation

enum RiskLevel: String {
    case low
    case medium
    case high
    case unknown

    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .unknown: return "Unrated"
        }
    }

    static func from(_ raw: String?) -> RiskLevel {
        guard let raw = raw?.lowercased() else { return .unknown }
        if raw.contains("high") { return .high }
        if raw.contains("med") { return .medium }
        if raw.contains("low") { return .low }
        return .unknown
    }
}

/// A review finding. The agent also reports the checks that passed, so a clean
/// review says something instead of showing an empty list.
enum FindingKind: String {
    case ok
    case warning
    case risk

    var isIssue: Bool { return self != .ok }

    static func from(_ raw: String?) -> FindingKind {
        guard let raw = raw?.lowercased().trimmingCharacters(in: .whitespaces) else { return .warning }
        // Exact matches only: "broken" must never read as "ok".
        if ["ok", "pass", "passed", "good", "clean", "fine"].contains(raw) { return .ok }
        if raw.contains("risk") || raw.contains("bug") || raw.contains("error")
            || raw.contains("critical") { return .risk }
        return .warning
    }
}

struct AIProblem: Identifiable, Hashable {
    let id = UUID()
    var kind: FindingKind = .warning
    var title: String
    var file: String?
    var line: Int?
    var severity: RiskLevel
    var detail: String

    var location: String? {
        guard let file, !file.isEmpty else { return nil }
        if let line, line > 0 { return "\(file):\(line)" }
        return file
    }

    static func == (lhs: AIProblem, rhs: AIProblem) -> Bool { return lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ReviewResult {
    var summary: String
    var risk: RiskLevel
    var problems: [AIProblem]
    var suggestions: [String]
    var rawText: String
    var parsed: Bool

    /// Everything the agent reported, passing checks included.
    var findings: [AIProblem] { return problems }
    /// Only what needs attention.
    var issues: [AIProblem] { return problems.filter { $0.kind.isIssue } }

    static func unparsed(_ text: String) -> ReviewResult {
        return ReviewResult(summary: text,
                            risk: .unknown,
                            problems: [],
                            suggestions: [],
                            rawText: text,
                            parsed: false)
    }
}

// MARK: - Tolerant JSON extraction

enum JSONExtractor {

    /// Finds the first balanced JSON object in arbitrary model output.
    static func firstObject(in text: String) -> [String: Any]? {
        let cleaned = stripFences(text)
        let characters = Array(cleaned)
        guard let start = characters.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < characters.count {
            let character = characters[index]
            if escaped {
                escaped = false
            } else if character == "\\" && inString {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        let slice = String(characters[start...index])
                        guard let data = slice.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                        return object
                    }
                }
            }
            index += 1
        }
        return nil
    }

    private static func stripFences(_ text: String) -> String {
        var value = text
        value = value.replacingOccurrences(of: "```json", with: "```")
        while let open = value.range(of: "```") {
            let afterOpen = value[open.upperBound...]
            guard let close = afterOpen.range(of: "```") else {
                value = String(value[open.upperBound...])
                break
            }
            value = String(afterOpen[..<close.lowerBound])
            break
        }
        return value
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let text = value as? String { return Int(text.filter { $0.isNumber }) }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? Int { return String(number) }
        return nil
    }
}

// MARK: - Review parsing

enum ReviewParser {

    static func parse(_ text: String) -> ReviewResult {
        guard let object = JSONExtractor.firstObject(in: text) else {
            return .unparsed(text)
        }

        let summary = JSONExtractor.string(object["summary"]) ?? ""
        let risk = RiskLevel.from(JSONExtractor.string(object["risk"]))

        var problems: [AIProblem] = []
        let rawFindings = (object["findings"] as? [[String: Any]])
            ?? (object["problems"] as? [[String: Any]])
            ?? []
        for entry in rawFindings {
            let title = JSONExtractor.string(entry["title"])
                ?? JSONExtractor.string(entry["problem"])
                ?? "Finding"
            let kind = FindingKind.from(JSONExtractor.string(entry["kind"])
                                        ?? JSONExtractor.string(entry["status"])
                                        ?? JSONExtractor.string(entry["severity"]))
            problems.append(AIProblem(
                kind: kind,
                title: title,
                file: JSONExtractor.string(entry["file"]),
                line: JSONExtractor.int(entry["line"]),
                severity: kind == .ok ? .low : RiskLevel.from(JSONExtractor.string(entry["severity"])),
                detail: JSONExtractor.string(entry["detail"]) ?? JSONExtractor.string(entry["description"]) ?? ""
            ))
        }

        var suggestions: [String] = []
        if let rawSuggestions = object["suggestions"] as? [Any] {
            for entry in rawSuggestions {
                if let text = entry as? String {
                    suggestions.append(text)
                } else if let dictionary = entry as? [String: Any] {
                    if let text = JSONExtractor.string(dictionary["suggestion"]) ?? JSONExtractor.string(dictionary["title"]) {
                        suggestions.append(text)
                    }
                }
            }
        }

        if summary.isEmpty && problems.isEmpty && suggestions.isEmpty {
            return .unparsed(text)
        }

        return ReviewResult(summary: summary,
                            risk: risk,
                            problems: problems,
                            suggestions: suggestions,
                            rawText: text,
                            parsed: true)
    }
}
