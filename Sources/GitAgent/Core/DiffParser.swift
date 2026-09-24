import Foundation

struct DiffLine: Identifiable {
    enum Kind {
        case context
        case addition
        case deletion
        case noNewline
    }

    let id: Int
    let kind: Kind
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
}

struct DiffHunk: Identifiable {
    let id: Int
    let header: String
    let lines: [DiffLine]
}

struct FileDiff {
    var path: String
    var hunks: [DiffHunk] = []
    var isBinary: Bool = false
    var additions: Int = 0
    var deletions: Int = 0
    var truncated: Bool = false

    var isEmpty: Bool { return hunks.isEmpty && !isBinary }
}

enum DiffParser {

    /// Maximum number of diff lines rendered for a single file.
    static let lineLimit = 4000

    static func parse(_ raw: String, path: String) -> FileDiff {
        var diff = FileDiff(path: path)
        guard !raw.isEmpty else { return diff }

        var hunks: [DiffHunk] = []
        var currentHeader: String?
        var currentLines: [DiffLine] = []
        var oldLine = 0
        var newLine = 0
        var lineID = 0
        var emitted = 0

        func closeHunk() {
            if let header = currentHeader {
                hunks.append(DiffHunk(id: hunks.count, header: header, lines: currentLines))
            }
            currentHeader = nil
            currentLines = []
        }

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            // A new file header ends the previous hunk. Everything else is only
            // treated as metadata while no hunk is open, otherwise a removed line
            // such as "-- foo" would be mistaken for a "--- " header.
            if line.hasPrefix("diff --git") {
                closeHunk()
                continue
            }
            if currentHeader == nil {
                if line.hasPrefix("Binary files") || line.hasPrefix("GIT binary patch") {
                    diff.isBinary = true
                    continue
                }
                if line.hasPrefix("index ")
                    || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
                    || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode")
                    || line.hasPrefix("old mode") || line.hasPrefix("new mode")
                    || line.hasPrefix("similarity index") || line.hasPrefix("dissimilarity index")
                    || line.hasPrefix("rename from") || line.hasPrefix("rename to")
                    || line.hasPrefix("copy from") || line.hasPrefix("copy to")
                    || line.hasPrefix("# staged changes") || line.hasPrefix("# unstaged changes") {
                    continue
                }
            }

            if line.hasPrefix("@@") {
                closeHunk()
                let range = parseHunkHeader(line)
                oldLine = range.0
                newLine = range.1
                currentHeader = line
                continue
            }

            guard currentHeader != nil else { continue }
            if emitted >= lineLimit {
                diff.truncated = true
                if line.hasPrefix("+") { newLine += 1 }
                else if line.hasPrefix("-") { oldLine += 1 }
                else if line.hasPrefix(" ") { oldLine += 1; newLine += 1 }
                continue
            }

            if line.hasPrefix("\\") {
                currentLines.append(DiffLine(id: lineID, kind: .noNewline, text: " No newline at end of file", oldNumber: nil, newNumber: nil))
                lineID += 1
                emitted += 1
                continue
            }

            let marker = line.first
            let body = String(line.dropFirst())
            switch marker {
            case "+":
                currentLines.append(DiffLine(id: lineID, kind: .addition, text: body, oldNumber: nil, newNumber: newLine))
                newLine += 1
                diff.additions += 1
            case "-":
                currentLines.append(DiffLine(id: lineID, kind: .deletion, text: body, oldNumber: oldLine, newNumber: nil))
                oldLine += 1
                diff.deletions += 1
            case " ":
                currentLines.append(DiffLine(id: lineID, kind: .context, text: body, oldNumber: oldLine, newNumber: newLine))
                oldLine += 1
                newLine += 1
            default:
                continue
            }
            lineID += 1
            emitted += 1
        }
        closeHunk()

        diff.hunks = hunks
        if !hunks.isEmpty { diff.isBinary = false }
        return diff
    }

    /// Reads the starting line numbers from "@@ -12,7 +12,9 @@ context".
    private static func parseHunkHeader(_ header: String) -> (Int, Int) {
        let tokens = header.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var oldStart = 1
        var newStart = 1
        for token in tokens.dropFirst() {
            if token == "@@" { break }
            if token.hasPrefix("-") {
                oldStart = Self.number(token) ?? 1
            } else if token.hasPrefix("+") {
                newStart = Self.number(token) ?? 1
            }
        }
        return (oldStart, newStart)
    }

    /// Reads the leading number of "-12,7" / "+12,9".
    private static func number(_ token: String) -> Int? {
        let body = token.dropFirst()
        guard let head = body.split(separator: ",").first else { return nil }
        return Int(String(head))
    }
}
