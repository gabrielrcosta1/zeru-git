import Foundation
import SwiftUI

/// Sync & Pull: bring the branch up to date without the user having to fight
/// git over the work in their tree.
///
/// The sequence is deliberately made of separate, visible commands rather than
/// one clever invocation. The user watches their work being put somewhere safe,
/// the remote arriving, and their work coming back, and if anything stops half
/// way they can see exactly where it stopped and where their work is. git's own
/// --autostash rides along on the rebase as a second safety net, for the case
/// where the tree becomes dirty again between two of these steps.
///
/// Nothing here discards anything. There is no reset, no checkout of a path, no
/// force, and no lock file is ever deleted.
@MainActor
final class SyncEngine: ObservableObject {

    @Published private(set) var run: SyncRun?
    @Published private(set) var running = false
    /// The step whose git output is open.
    @Published var openStep: UUID?

    private let repository: GitRepository
    weak var session: ProjectSession?
    private var task: Task<Void, Never>?

    init(repository: GitRepository) {
        self.repository = repository
    }

    func teardown() {
        task?.cancel()
        task = nil
    }

    /// Starts one synchronisation. A second click while one is running does
    /// nothing at all, which is the first half of "one git operation at a time".
    func start() {
        guard !running, task == nil else { return }
        task = Task { @MainActor [weak self] in
            await self?.execute()
            self?.task = nil
        }
    }

    func clear() {
        guard !running else { return }
        run = nil
        openStep = nil
    }

    var canStart: Bool {
        guard !running, task == nil, let session else { return false }
        return session.repo != nil && !session.isBusy
    }

    // MARK: - The sequence

    private func execute() async {
        guard let session else { return }

        var current = SyncRun()
        current.steps = [
            SyncStep(phase: .checking, title: SyncPhase.checking.title),
            SyncStep(phase: .protecting, title: SyncPhase.protecting.title),
            SyncStep(phase: .fetching, title: SyncPhase.fetching.title),
            SyncStep(phase: .synchronizing, title: SyncPhase.synchronizing.title),
            SyncStep(phase: .restoring, title: SyncPhase.restoring.title),
            SyncStep(phase: .verifying, title: SyncPhase.verifying.title)
        ]

        // Another operation of this app's own. The runner would serialise it
        // anyway, but queueing behind a push and then rebasing on top of
        // whatever it left is not what the user asked for.
        if session.isBusy {
            current.begin(.checking)
            fail(&current,
                 phase: .checking,
                 problem: "Unable to synchronize because this app is already working in this repository.",
                 hint: session.busyLabel.map { "\($0). Wait for it to finish and press Sync again." }
                     ?? "Wait for the operation in progress to finish and press Sync again.")
            run = current
            return
        }

        running = true
        session.phase = .syncing
        run = current
        session.log(.info, "Sync started")
        let headBefore = await repository.head()

        // MARK: Checking

        current.begin(.checking)
        run = current

        guard let state = session.repo else {
            fail(&current, phase: .checking,
                 problem: "The repository is still loading.",
                 hint: "Try again in a moment.")
            await finish(current)
            return
        }
        current.branch = state.branchLabel
        current.aheadAtStart = state.ahead
        current.behindAtStart = state.behind

        if state.detached {
            fail(&current, phase: .checking,
                 problem: "HEAD is detached, so there is no branch to synchronize.",
                 hint: "Create a branch here first, or switch to one.")
            await finish(current)
            return
        }
        if state.isMerging || state.isRebasing {
            fail(&current, phase: .checking,
                 problem: "A merge or rebase is already in progress in this repository.",
                 hint: "Finish or abort it first \u{2014} the conflict panel has both.")
            await finish(current)
            return
        }
        if state.hasConflicts {
            fail(&current, phase: .checking,
                 problem: "There are unresolved conflicts in the working tree.",
                 hint: "Resolve them and commit before synchronizing.")
            await finish(current)
            return
        }

        // The lock, handled honestly: waited for when it is ours, reported when
        // it is somebody else's, never deleted here.
        if let problem = await waitForLock(&current) {
            fail(&current, phase: .checking, problem: problem.0, hint: problem.1)
            await finish(current)
            return
        }

        guard let upstream = await repository.upstreamRef() else {
            fail(&current, phase: .checking,
                 problem: "\(state.branchLabel) does not track a branch on the remote.",
                 hint: "Push it once with Commit & Push and git will set the upstream.")
            await finish(current)
            return
        }
        current.upstream = upstream
        let remote = upstream.contains("/") ? String(upstream.split(separator: "/")[0]) : "origin"
        current.mark(.checking, .done, detail: "\(state.branchLabel) tracks \(upstream)")
        run = current

        // MARK: Fetching

        current.begin(.fetching)
        run = current
        let fetched = await command(["fetch", "--quiet", remote], timeout: 120)
        guard fetched.ok else {
            current.mark(.fetching, .failed, output: fetched.text)
            let described = GitFailure.describe(fetched.error)
            fail(&current, phase: .fetching,
                 problem: "Could not reach \(remote).",
                 hint: described.hint ?? "Nothing in your working tree was touched. Check the connection, then press Sync again.",
                 technical: fetched.text)
            await finish(current)
            return
        }
        current.mark(.fetching, .done)
        run = current

        // Nothing came in: no reason to touch the working tree at all.
        let distance = await repository.distance(to: upstream)
        let behind = distance?.behind ?? 0
        let ahead = distance?.ahead ?? 0
        current.behindAtStart = behind
        current.aheadAtStart = ahead
        if behind == 0 {
            current.mark(.protecting, .skipped, detail: "nothing to protect")
            current.mark(.synchronizing, .skipped, detail: "already up to date with \(upstream)")
            current.mark(.restoring, .skipped, detail: "nothing to restore")
            await verify(&current, expectBehindZero: true, upstream: upstream)
            if current.phase == .failed || current.phase == .conflict {
                await finish(current)
                return
            }
            current.phase = .completed
            session.log(.success, "Sync: already up to date with \(upstream)")
            await finish(current, record: false)
            return
        }

        // MARK: Protecting

        let dirty = session.repo?.hasChanges == true
        if dirty {
            current.begin(.protecting)
            run = current
            let message = "git-agent sync: \(state.branchLabel) \(SyncEngine.stamp.string(from: Date()))"
            let count = session.repo?.changes.count ?? 0
            let stashed = await command(["stash", "push", "--include-untracked", "-m", message], timeout: 120)
            guard stashed.ok else {
                current.mark(.protecting, .failed, output: stashed.text)
                fail(&current, phase: .protecting,
                     problem: "Your local changes could not be put aside, so nothing was synchronized.",
                     hint: "Your files are exactly as they were. Commit them, or look at the details below.",
                     technical: stashed.text)
                await finish(current)
                return
            }
            if stashed.text.contains("No local changes to save") {
                // git found nothing of its own to save. Say so rather than
                // claiming to have protected something.
                current.mark(.protecting, .skipped, detail: "git had nothing it could put aside", output: stashed.text)
            } else {
                current.stashMessage = message
                current.stashedCount = count
                current.stashRef = await repository.stashRef(withMessage: message)
                current.mark(.protecting, .done,
                             detail: "\(count) change\(count == 1 ? "" : "s") in the stash",
                             output: stashed.text)
                session.log(.success, "Sync: \(count) change(s) stashed")
            }
            run = current
            await session.refreshStash()
        } else {
            current.mark(.protecting, .skipped, detail: "no local changes")
            run = current
        }

        // MARK: Synchronizing

        current.begin(.synchronizing)
        run = current
        // --autostash is the second net: if the tree became dirty again between
        // the stash above and this line, git puts it aside and brings it back
        // itself instead of refusing.
        let synced = await command(["rebase", "--autostash", upstream], timeout: 600)
        guard synced.ok else {
            current.mark(.synchronizing, .failed, output: synced.text)
            await session.refresh(silent: true)
            let conflicts = session.repo?.conflicts.map { $0.path } ?? []
            if !conflicts.isEmpty || session.repo?.isRebasing == true {
                current.conflicts = conflicts
                stopOnConflict(&current,
                               problem: "\(upstream) and your commits changed the same lines.",
                               hint: current.workIsParked
                                   ? "Nothing was lost. Resolve the conflicts and continue the rebase; your uncommitted work is still in the stash and goes back afterwards."
                                   : "Nothing was lost. Resolve the conflicts and continue the rebase, or abort it to go back to where you were.",
                               technical: synced.text)
            } else {
                fail(&current, phase: .synchronizing,
                     problem: "The branch could not be synchronized with \(upstream).",
                     hint: current.workIsParked
                         ? "Your uncommitted work is safe in the stash and was not touched."
                         : "Nothing in your working tree was changed.",
                     technical: synced.text)
            }
            await finish(current)
            return
        }
        current.mark(.synchronizing, .done,
                     detail: ahead > 0
                         ? "\(behind) commit\(behind == 1 ? "" : "s") in, \(ahead) of yours replayed on top"
                         : "\(behind) commit\(behind == 1 ? "" : "s") in",
                     output: synced.text)
        run = current
        session.log(.success, "Sync: \(state.branchLabel) is level with \(upstream)")

        // A rebase that exits zero is not proof of a clean tree. git applies an
        // --autostash AFTER the rebase, and when that conflicts it says
        // "Applying autostash resulted in conflicts", pushes the autostash onto
        // the stash list and still exits zero. Popping our own stash on top of
        // that would fail on an unmerged path and be reported as the user's
        // changes conflicting, which it is not.
        await session.refresh(silent: true)
        if session.repo?.hasConflicts == true {
            current.conflicts = session.repo?.conflicts.map { $0.path } ?? []
            current.mark(.synchronizing, .failed, output: synced.text)
            stopOnConflict(&current,
                           problem: "The branch is up to date, but putting the working tree back conflicted.",
                           hint: current.workIsParked
                               ? "Nothing was lost. Resolve the files below; your stashed changes were not applied and are still in the stash."
                               : "Nothing was lost. Resolve the files below \u{2014} git kept what it could not apply in the stash.",
                           technical: synced.text)
            await session.refreshStash()
            await finish(current)
            return
        }

        // MARK: Restoring

        if current.stashMessage != nil {
            current.begin(.restoring)
            run = current
            // Resolved again here: stash@{N} renumbers whenever anything else
            // touches the stash, and popping the wrong entry would be the one
            // unforgivable bug in this whole flow.
            let ref = await repository.stashRef(withMessage: current.stashMessage ?? "")
            guard let ref else {
                current.mark(.restoring, .failed)
                fail(&current, phase: .restoring,
                     problem: "The stash holding your changes could not be found again.",
                     hint: "Nothing was deleted. Open the Stashes panel (\u{2318}3) and restore it from there.")
                await finish(current)
                return
            }
            let restored = await command(["stash", "pop", ref], timeout: 120)
            if restored.ok {
                current.stashRestored = true
                current.stashRef = nil
                current.mark(.restoring, .done,
                             detail: "\(current.stashedCount) change\(current.stashedCount == 1 ? "" : "s") back in place",
                             output: restored.text)
                run = current
            } else {
                current.mark(.restoring, .failed, output: restored.text)
                await session.refresh(silent: true)
                current.conflicts = session.repo?.conflicts.map { $0.path } ?? []
                // git keeps the entry when a pop conflicts. That is the whole
                // safety net and the user must be told it is still there.
                // Two failures wear the same exit code. A real conflict leaves
                // markers in the files; a refusal ("already exists, no
                // checkout") applies nothing at all, and telling the user their
                // work is in the files sends them looking for what is not there.
                let merged = session.repo?.hasConflicts == true
                stopOnConflict(&current,
                               problem: merged
                                   ? "Your changes and the commits that came in touch the same lines."
                                   : "Your changes could not be put back: something now on disk is in the way.",
                               hint: merged
                                   ? "Nothing was lost. Your work is in the files, with the conflict markers, and git also kept the stash entry \u{2014} so you can resolve it here or start again from the stash."
                                   : "Nothing was lost. Your work is still in the stash exactly as it was; open the Stashes panel (\u{2318}3) and apply it once the file in the way is dealt with.",
                               technical: restored.text)
                await finish(current)
                return
            }
            await session.refreshStash()
        } else {
            current.mark(.restoring, .skipped, detail: "nothing to restore")
            run = current
        }

        // MARK: Verifying

        await verify(&current, expectBehindZero: true, upstream: upstream)
        if current.phase == .failed || current.phase == .conflict {
            await finish(current)
            return
        }
        current.phase = .completed
        await finish(current, headBefore: headBefore)
    }

    // MARK: - Steps that are their own small problem

    /// Reads back what the repository looks like now, and refuses to call the
    /// run a success if anything is missing.
    private func verify(_ current: inout SyncRun, expectBehindZero: Bool, upstream: String) async {
        guard let session else { return }
        current.begin(.verifying)
        run = current

        await session.refresh(silent: true)
        await session.loadBranches()
        await session.refreshStash()

        var notes: [String] = []
        if let distance = await repository.distance(to: upstream) {
            if expectBehindZero, distance.behind > 0 {
                current.mark(.verifying, .failed)
                fail(&current, phase: .verifying,
                     problem: "The branch is still \(distance.behind) commit\(distance.behind == 1 ? "" : "s") behind \(upstream).",
                     hint: "Nothing was lost. Press Sync again, or look at what the steps above reported.")
                return
            }
            notes.append(distance.ahead > 0 ? "\(distance.ahead) of yours to push" : "level with \(upstream)")
        }

        // The one thing that would be unforgivable: work that went into the
        // stash and did not come back.
        if current.stashRestored, current.stashedCount > 0, session.repo?.hasChanges != true {
            current.mark(.verifying, .failed)
            fail(&current, phase: .verifying,
                 problem: "Your changes were restored but the working tree looks clean.",
                 hint: "Check the Stashes panel (\u{2318}3) before doing anything else \u{2014} nothing was deleted by this app.")
            return
        }
        if session.repo?.hasChanges == true {
            let count = session.repo?.changes.count ?? 0
            notes.append("\(count) local change\(count == 1 ? "" : "s") preserved")
        }
        if session.repo?.hasConflicts == true {
            current.conflicts = session.repo?.conflicts.map { $0.path } ?? []
            current.mark(.verifying, .failed)
            stopOnConflict(&current,
                           problem: "There are conflicts in the working tree.",
                           hint: "Nothing was lost. Resolve them in the conflict panel.")
            return
        }
        current.mark(.verifying, .done, detail: notes.joined(separator: " \u{00b7} "))
        run = current
    }

    /// Waits while the lock belongs to this app, reports when it does not, and
    /// never removes anything.
    private func waitForLock(_ current: inout SyncRun) async -> (String, String)? {
        guard var info = await repository.lockInfo() else { return nil }

        if info.heldByUs {
            current.mark(.checking, .running, detail: "waiting for this app's own git process")
            run = current
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let again = await repository.lockInfo() else { return nil }
                info = again
                if !info.heldByUs { break }
            }
            if info.heldByUs {
                return ("Another git command started by this app is still holding the index.",
                        "It has been running for a while. Wait for it to finish, or stop it from the lock dialog.")
            }
        }

        if info.isHeld {
            let names = info.realHolders.map { $0.label }.joined(separator: ", ")
            return ("Unable to synchronize because another program is using this repository's index.",
                    "Held by \(names). Close it, or wait for it to finish, and press Sync again.")
        }

        if info.looksStale {
            // The safe recovery path already exists, asks before removing, and
            // comes back here afterwards. Nothing is deleted on our own say-so.
            session?.lockAlert = LockAlert(detail: "The lock file is \(info.ageText) and nothing seems to hold it.\n\n\(info.path)",
                                           lockPath: info.path,
                                           canRemove: true,
                                           stoppable: info.ourHolders.map { $0.pid },
                                           // The run that opened this alert is
                                           // still finishing; starting before
                                           // it lets go would be swallowed.
                                           retry: { [weak self] in
                                               await self?.task?.value
                                               self?.start()
                                           })
            return ("A leftover index.lock is in the way.",
                    "Nothing holds it and it is \(info.ageText). The dialog that just opened can remove it, and then Sync runs again.")
        }

        return ("Unable to synchronize because this repository's index is locked.",
                "The lock is \(info.ageText)\(info.probed ? "" : " and could not be inspected"). Wait a moment and press Sync again.")
    }

    // MARK: - Small helpers

    private struct Outcome {
        let ok: Bool
        let text: String
        let error: Error
    }

    /// One git command, with its output kept whichever way it went.
    private func command(_ arguments: [String], timeout: TimeInterval) async -> Outcome {
        do {
            let result = try await repository.syncRun(arguments, timeout: timeout)
            let text = (result.stdout + "\n" + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            let error = ShellError.failed(command: "git " + arguments.joined(separator: " "),
                                          status: result.status,
                                          stderr: result.stderr.isEmpty ? result.stdout : result.stderr)
            return Outcome(ok: result.ok, text: text, error: error)
        } catch {
            return Outcome(ok: false,
                           text: GitFailure.describe(error).full,
                           error: error)
        }
    }

    private func fail(_ current: inout SyncRun,
                      phase: SyncPhase,
                      problem: String,
                      hint: String?,
                      technical: String? = nil) {
        current.mark(phase, .failed)
        for index in current.steps.indices where current.steps[index].state == .pending {
            current.steps[index].state = .skipped
        }
        current.phase = .failed
        current.problem = problem
        current.hint = hint
        current.technical = technical
        run = current
    }

    private func stopOnConflict(_ current: inout SyncRun,
                                problem: String,
                                hint: String,
                                technical: String? = nil) {
        for index in current.steps.indices where current.steps[index].state == .pending {
            current.steps[index].state = .skipped
        }
        current.phase = .conflict
        current.problem = problem
        current.hint = hint
        current.technical = technical
        run = current
    }

    private func finish(_ current: SyncRun, headBefore: String? = nil, record: Bool = true) async {
        var finished = current
        finished.finishedAt = Date()
        run = finished
        running = false
        if session?.phase == .syncing { session?.phase = .ready }

        switch finished.phase {
        case .completed:
            session?.flash("Synced \u{00b7} " + (finished.stashedCount > 0 && finished.stashRestored
                                                 ? "your changes are back"
                                                 : "up to date"))
        case .conflict:
            session?.log(.warning, "Sync stopped on a conflict")
        case .failed:
            session?.log(.failure, "Sync failed: " + (finished.problem ?? "unknown"))
        default:
            break
        }

        if record {
            await session?.recordSync(finished, headBefore: headBefore)
        }
        await session?.refresh(silent: true)
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM HH:mm:ss"
        return formatter
    }()
}
