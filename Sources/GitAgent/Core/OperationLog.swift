import CryptoKit
import Foundation

// MARK: - What happened

/// One kind of thing that can happen to a repository. Only operations the app
/// itself performed are recorded: this is a record of what Git Agent did, not
/// an interpretation of the repository's history.
enum GitOperation: String, Codable {
    case commit
    case push
    case pull
    case fetch
    case checkout
    case branchCreate
    case stash
    case stashApply
    case stashPop
    case stashDrop
    case stashBranch
    case discard
    case rebaseAbort
    case conflictResolve
    case aiFix
    case recoverBranch
    case recoverReset
    case rebase
    case aiCommand
    case workflow

    var label: String {
        switch self {
        case .commit: return "Commit"
        case .push: return "Push"
        case .pull: return "Pull"
        case .fetch: return "Fetch"
        case .checkout: return "Checkout"
        case .branchCreate: return "New branch"
        case .stash: return "Stash"
        case .stashApply: return "Stash apply"
        case .stashPop: return "Stash pop"
        case .stashDrop: return "Stash drop"
        case .stashBranch: return "Branch from stash"
        case .discard: return "Discard"
        case .rebaseAbort: return "Rebase aborted"
        case .conflictResolve: return "Conflicts resolved"
        case .aiFix: return "AI fix"
        case .recoverBranch: return "Restored as branch"
        case .recoverReset: return "Moved branch back"
        case .rebase: return "Rebase"
        case .aiCommand: return "AI ran"
        case .workflow: return "Workflow"
        }
    }

    /// Operations that moved HEAD, so recording where it was is worth the
    /// extra `rev-parse`.
    var movesHead: Bool {
        switch self {
        case .commit, .pull, .checkout, .branchCreate, .stashBranch, .rebaseAbort, .conflictResolve:
            return true
        case .push, .fetch, .stash, .stashApply, .stashPop, .stashDrop, .discard, .aiFix,
             .recoverBranch:
            return false
        case .recoverReset, .rebase, .aiCommand, .workflow:
            return true
        }
    }
}

/// One line of the timeline. Written once, never edited.
struct OperationRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date
    let operation: GitOperation
    /// The main line: a commit subject, a branch name, a stash message.
    let subject: String
    /// A second, quieter line. Counts, remotes, that sort of thing.
    let detail: String?
    /// Where HEAD was before and after, when the operation moved it. This is
    /// what tells the app which commit a recovery would go back to.
    let headBefore: String?
    let headAfter: String?
    let branch: String?
    /// False for an operation that was attempted and failed. The timeline says
    /// what happened, including the things that did not work.
    let ok: Bool

    init(operation: GitOperation,
         subject: String,
         detail: String? = nil,
         headBefore: String? = nil,
         headAfter: String? = nil,
         branch: String? = nil,
         ok: Bool = true,
         date: Date = Date()) {
        self.id = UUID()
        self.date = date
        self.operation = operation
        self.subject = subject
        self.detail = detail
        self.headBefore = headBefore
        self.headAfter = headAfter
        self.branch = branch
        self.ok = ok
    }

    /// Fixed-format formatters are expensive to build and the timeline reads
    /// them for every row on every redraw, so there is one of each.
    /// POSIX locale: "HH:mm" and "yyyy-MM-dd" must not pick up the user's
    /// calendar or numeral system.
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dayInYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM"
        return formatter
    }()

    private static let dayWithYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()

    var time: String {
        return OperationRecord.clock.string(from: date)
    }

    /// "TODAY", "YESTERDAY", "12 MARCH", "12 MARCH 2025". One string per day,
    /// so the timeline can group on it.
    var dayTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let sameYear = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        return sameYear
            ? OperationRecord.dayInYear.string(from: date)
            : OperationRecord.dayWithYear.string(from: date)
    }

    /// Sortable, stable key for the day this record belongs to.
    var dayKey: String {
        return OperationRecord.dayStamp.string(from: date)
    }

    var shortHeadBefore: String? {
        guard let headBefore, headBefore.count >= 7 else { return nil }
        return String(headBefore.prefix(7))
    }
}

// MARK: - Storage

/// The timeline of one repository, kept on disk so it survives a restart.
///
/// It lives in Application Support, never inside the user's repository: the
/// app does not add files to a project to keep notes about it.
actor OperationLog {

    /// Older records are dropped from the file, oldest first.
    private let limit = 400

    private let root: URL
    private let directory: URL
    private let file: URL
    private var records: [OperationRecord] = []
    private var loaded = false

    init(root: URL) {
        // Symlinks resolved: /tmp/x and /private/tmp/x are one repository, and
        // must not end up with two separate timelines.
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.directory = OperationLog.directory(for: self.root)
        self.file = directory.appendingPathComponent("operations.json")
    }

    /// Oldest first, the order the timeline groups on.
    func load() -> [OperationRecord] {
        if loaded { return records }
        loaded = true

        let exists = FileManager.default.fileExists(atPath: file.path)
        guard exists else { return records }

        guard let data = try? Data(contentsOf: file) else {
            // The file is there but unreadable right now. Starting a new log
            // would overwrite it on the next append, so it is set aside first.
            setAside()
            return records
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode(Stored.self, from: data) else {
            setAside()
            return records
        }
        records = stored.records
        return records
    }

    /// Renames a log that could not be read, so a fresh one can be written
    /// without destroying whatever was in it.
    private func setAside() {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let target = directory.appendingPathComponent("operations-unreadable-\(stamp).json")
        try? FileManager.default.moveItem(at: file, to: target)
    }

    /// The records after the append, and whether they actually reached the
    /// disk. A timeline the app cannot write is worth saying out loud rather
    /// than showing on screen and losing on quit.
    struct AppendResult: Sendable {
        let records: [OperationRecord]
        let saved: Bool
    }

    @discardableResult
    func append(_ record: OperationRecord) -> AppendResult {
        _ = load()
        records.append(record)
        if records.count > limit { records.removeFirst(records.count - limit) }
        return AppendResult(records: records, saved: save())
    }

    @discardableResult
    private func save() -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(Stored(root: root.path, records: records)) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private struct Stored: Codable {
        let root: String
        let records: [OperationRecord]
    }

    // MARK: Location

    /// One folder per repository path. The name carries the project name so the
    /// folder is recognisable, and a digest so two projects with the same name
    /// never share a log.
    private static func directory(for root: URL) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("GitAgent", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(folderName(for: root), isDirectory: true)
    }

    private static func folderName(for root: URL) -> String {
        var name = ""
        for character in root.lastPathComponent {
            if character.isASCII && (character.isLetter || character.isNumber) {
                name.append(character)
            } else if !name.isEmpty && !name.hasSuffix("-") {
                name.append("-")
            }
        }
        while name.hasSuffix("-") { name.removeLast() }
        if name.count > 40 { name = String(name.prefix(40)) }
        let digest = SHA256.hash(data: Data(root.path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let suffix = String(hex.prefix(10))
        return name.isEmpty ? suffix : name + "-" + suffix
    }
}
