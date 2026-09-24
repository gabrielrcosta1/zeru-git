import Foundation

/// Where a synchronisation is. Every one of these is a real moment in the
/// sequence, not a label put over a single opaque command: the user watches
/// their work being protected, the remote arriving, and their work coming back.
enum SyncPhase: String, Hashable {
    case checking
    case protecting
    case fetching
    case synchronizing
    case restoring
    case verifying
    case completed
    case conflict
    case failed

    /// What the user reads while it is happening.
    var progressLabel: String {
        switch self {
        case .checking: return "Preparing synchronization\u{2026}"
        case .protecting: return "Protecting local changes\u{2026}"
        case .fetching: return "Fetching remote changes\u{2026}"
        case .synchronizing: return "Synchronizing\u{2026}"
        case .restoring: return "Restoring local changes\u{2026}"
        case .verifying: return "Verifying repository\u{2026}"
        case .completed: return "Synced successfully."
        case .conflict: return "Stopped on a conflict."
        case .failed: return "Could not synchronize."
        }
    }

    /// The name of the step, for the list.
    var title: String {
        switch self {
        case .checking: return "Check the repository"
        case .protecting: return "Protect local changes"
        case .fetching: return "Fetch from the remote"
        case .synchronizing: return "Synchronize the branch"
        case .restoring: return "Restore local changes"
        case .verifying: return "Verify the result"
        case .completed: return "Done"
        case .conflict: return "Conflict"
        case .failed: return "Failed"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .conflict, .failed: return true
        default: return false
        }
    }
}

/// One step of the sequence. The state reuses the workflow vocabulary so the
/// two panels read the same way and share their colours and icons.
struct SyncStep: Identifiable, Hashable {
    let id = UUID()
    let phase: SyncPhase
    var title: String
    /// What it actually did, once it is known: "3 files stashed", "skipped".
    var detail: String?
    var state: WorkflowStepState = .pending
    /// git's own output, shown only when the user opens it.
    var output: String = ""
    var duration: TimeInterval = 0
}

/// One synchronisation, from the click to whatever it ended as.
struct SyncRun {
    var phase: SyncPhase = .checking
    var steps: [SyncStep] = []
    var startedAt = Date()
    var finishedAt: Date?

    /// The sentence the user reads. Never git's raw output.
    var problem: String?
    /// What they can do about it.
    var hint: String?
    /// git's own words, behind a disclosure.
    var technical: String?

    /// The branch and where it was going.
    var branch: String = ""
    var upstream: String?
    var behindAtStart = 0
    var aheadAtStart = 0

    /// The stash this run made, while it still exists. This is the proof that
    /// nothing was thrown away, and it is shown as long as it is there.
    var stashRef: String?
    var stashMessage: String?
    var stashedCount = 0
    /// Set once the stash has been applied and dropped by git.
    var stashRestored = false

    var conflicts: [String] = []

    var duration: TimeInterval {
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var durationLabel: String {
        let seconds = duration
        if seconds < 1 { return "under a second" }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        return String(format: "%dm %02ds", Int(seconds) / 60, Int(seconds) % 60)
    }

    /// True while the user's work is sitting in a stash this app made.
    ///
    /// Keyed on the message, not on the ref: the ref is a stash@{N} that may
    /// have failed to resolve, and reporting "nothing was parked" about work
    /// that is in fact parked is the one lie this panel must never tell.
    var workIsParked: Bool {
        return stashMessage != nil && !stashRestored
    }

    mutating func mark(_ phase: SyncPhase,
                       _ state: WorkflowStepState,
                       detail: String? = nil,
                       output: String? = nil) {
        guard let index = steps.firstIndex(where: { $0.phase == phase }) else { return }
        steps[index].state = state
        if let detail { steps[index].detail = detail }
        if let output, !output.isEmpty {
            steps[index].output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    mutating func begin(_ phase: SyncPhase) {
        self.phase = phase
        mark(phase, .running)
    }
}
