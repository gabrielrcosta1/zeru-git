import CryptoKit
import Foundation

// MARK: - A run

enum WorkflowStepState: String, Codable, Hashable {
    case pending
    case running
    case done
    case failed
    case skipped

    var isTerminal: Bool {
        switch self {
        case .pending, .running: return false
        case .done, .failed, .skipped: return true
        }
    }
}

struct WorkflowRunStep: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: WorkflowStepKind
    var title: String
    /// The command as it ran, for anyone who wants to see it.
    var command: String
    var each: String?
    var state: WorkflowStepState = .pending
    var output: String = ""
    var duration: TimeInterval = 0

    var durationLabel: String {
        if duration < 1 { return String(format: "%.0fms", duration * 1000) }
        return String(format: "%.1fs", duration)
    }

    /// The first lines, which is all a row shows until it is opened.
    var summary: String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.first.map(String.init) ?? ""
    }
}

enum WorkflowOutcome: String, Codable, Hashable {
    case running
    case completed
    case failed
    case aborted

    var label: String {
        switch self {
        case .running: return "Running"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .aborted: return "Aborted"
        }
    }
}

struct WorkflowRun: Identifiable, Codable, Hashable {
    var id = UUID()
    var workflowID: UUID
    var workflowName: String
    var flowLabel: String
    var startedAt = Date()
    var finishedAt: Date?
    var outcome: WorkflowOutcome = .running
    var steps: [WorkflowRunStep] = []
    /// Why it stopped, when it did.
    var problem: String?

    var duration: TimeInterval {
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var durationLabel: String {
        let seconds = duration
        if seconds < 1 { return "under a second" }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        return String(format: "%dm %02ds", Int(seconds) / 60, Int(seconds) % 60)
    }

    var failedIndex: Int? {
        return steps.firstIndex { $0.state == .failed }
    }

    var doneCount: Int { return steps.filter { $0.state == .done }.count }

    /// "Today 07:42", "Yesterday 18:21", "8 Sep 14:03".
    var whenLabel: String {
        let calendar = Calendar.current
        let time = WorkflowRun.clock.string(from: startedAt)
        if calendar.isDateInToday(startedAt) { return "Today " + time }
        if calendar.isDateInYesterday(startedAt) { return "Yesterday " + time }
        return WorkflowRun.day.string(from: startedAt) + " " + time
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM"
        return formatter
    }()
}

// MARK: - A check before it starts

struct WorkflowCheck: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let passed: Bool
    /// Why it did not pass, and what to do about it.
    let detail: String?
}

// MARK: - Storage

/// The workflows of one repository and the record of what they did.
///
/// Lives in Application Support next to that project's timeline, never inside
/// the repository: a workflow is how this person works, not part of the code.
actor WorkflowStore {

    /// Runs kept per workflow. Older ones fall off.
    private let runLimit = 40

    private let root: URL
    private let directory: URL
    private let workflowFile: URL
    private let runFile: URL

    private var workflows: [GitWorkflow] = []
    private var runs: [WorkflowRun] = []
    private var loaded = false

    init(root: URL) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.directory = WorkflowStore.directory(for: self.root)
        self.workflowFile = directory.appendingPathComponent("workflows.json")
        self.runFile = directory.appendingPathComponent("runs.json")
    }

    struct Contents: Sendable {
        var workflows: [GitWorkflow]
        var runs: [WorkflowRun]
        /// The workflow file was there and could not be read. An empty library
        /// then means "could not tell", never "none yet", and nothing may be
        /// written over it on that basis.
        var unreadable: Bool
    }

    private var unreadable = false

    func load() -> Contents {
        if loaded { return Contents(workflows: workflows, runs: runs, unreadable: unreadable) }
        loaded = true
        let stored = read([GitWorkflow].self, from: workflowFile)
        unreadable = stored == nil && FileManager.default.fileExists(atPath: setAsidePath(workflowFile))
        workflows = stored ?? []
        runs = read([WorkflowRun].self, from: runFile) ?? []
        return Contents(workflows: workflows, runs: runs, unreadable: unreadable)
    }

    @discardableResult
    func save(workflows value: [GitWorkflow]) -> Bool {
        _ = load()
        workflows = value
        return write(workflows, to: workflowFile)
    }

    /// The runs after the save, and whether it reached the disk.
    struct RunSave: Sendable {
        var runs: [WorkflowRun]
        var saved: Bool
    }

    @discardableResult
    func save(run: WorkflowRun) -> RunSave {
        _ = load()
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.append(run)
        }
        // Trim per workflow, so a busy one never buries a quiet one.
        var kept: [WorkflowRun] = []
        var counts: [UUID: Int] = [:]
        for entry in runs.sorted(by: { $0.startedAt > $1.startedAt }) {
            let count = counts[entry.workflowID, default: 0]
            guard count < runLimit else { continue }
            counts[entry.workflowID] = count + 1
            kept.append(entry)
        }
        runs = kept.sorted { $0.startedAt < $1.startedAt }
        return RunSave(runs: runs, saved: write(runs, to: runFile))
    }

    @discardableResult
    func removeRuns(ofWorkflow id: UUID) -> [WorkflowRun] {
        _ = load()
        runs.removeAll { $0.workflowID == id }
        _ = write(runs, to: runFile)
        return runs
    }

    // MARK: Files

    private func read<T: Decodable>(_ type: T.Type, from file: URL) -> T? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let data = try? Data(contentsOf: file) else {
            setAside(file)
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(T.self, from: data) else {
            setAside(file)
            return nil
        }
        return value
    }

    private func write<T: Encodable>(_ value: T, to file: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// A file that cannot be read is renamed, never written over: whatever is
    /// in it is the user's work.
    private func setAside(_ file: URL) {
        let name = file.deletingPathExtension().lastPathComponent
        let target = URL(fileURLWithPath: setAsidePath(file))
        // One name, so the app can tell afterwards that this happened. A file
        // already sitting there is the earlier copy, and it stays.
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        _ = name
        try? FileManager.default.moveItem(at: file, to: target)
    }

    private func setAsidePath(_ file: URL) -> String {
        let name = file.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent("\(name)-unreadable.json").path
    }

    /// The same folder the timeline uses, so one project is one place on disk.
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
