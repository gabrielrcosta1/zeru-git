import Foundation

/// Runs git for one repository, strictly one process at a time, and retries the
/// transient lock contention that happens when another tool touches the index.
///
/// Actor isolation alone is not enough here: actors are reentrant at every
/// `await`, so two calls awaiting a subprocess would overlap. Each invocation
/// therefore chains onto the previous one.
///
/// There used to be a second queue for fetch and push, on the reasoning that
/// they never take the index lock. Two things were wrong with it. A fetch on
/// that queue could run at the same moment as a pull on this one, and both
/// write FETCH_HEAD and the same remote-tracking refs, which is "cannot lock
/// ref" and "could not write index" arriving out of nowhere. And the moment a
/// second queue exists, "only one git process per repository" stops being true
/// for anything that comes later. One queue, one process, no exceptions: a
/// push that waits on credentials delays a status refresh, and that is a far
/// better failure than a repository two commands are fighting over.
///
/// One runner per repository is the other half of the guarantee, and the
/// workspace gives it: opening a folder that is already open brings its tab
/// forward instead of building a second session.
actor GitRunner {
    private let root: URL
    private let baseArguments = ["-c", "core.quotePath=false"]

    /// Extra attempts after the first, with a short backoff in between.
    private let lockRetries = 3

    private var tail: Task<Void, Never>?
    private var cachedGitDirectory: URL?

    /// The subcommand running right now, for whoever needs to say what the
    /// repository is busy with. Nil when nothing of ours is running.
    private(set) var current: String?
    /// How many calls are waiting for their turn, the running one included.
    private(set) var queued = 0

    init(root: URL) {
        self.root = root
    }

    /// What this app is doing to this repository at this instant.
    var activity: (command: String, waiting: Int)? {
        guard let current else { return nil }
        return (current, max(0, queued - 1))
    }

    func run(_ arguments: [String],
             env: [String: String] = [:],
             timeout: TimeInterval? = nil) async throws -> CommandResult {
        let previous = tail
        queued += 1
        let work = Task<CommandResult, Error> {
            await previous?.value
            return try await self.execute(arguments, env: env, timeout: timeout)
        }
        // The queue carries completion only, so a finished call does not keep
        // its output alive until the next one replaces it.
        tail = Task<Void, Never> { _ = try? await work.value }
        defer { queued -= 1 }
        return try await work.value
    }

    /// The git directory cannot change while a project is open, so it is read
    /// once instead of on every refresh.
    func gitDirectory() async -> URL? {
        if let cachedGitDirectory { return cachedGitDirectory }
        guard let result = try? await run(["rev-parse", "--absolute-git-dir"]), result.ok else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        cachedGitDirectory = url
        return url
    }

    /// Kept as its own entry point because fetch and push need their own
    /// timeout, but it is the same queue as everything else.
    func runNetwork(_ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        return try await run(arguments, timeout: timeout)
    }

    private func execute(_ arguments: [String],
                         env: [String: String] = [:],
                         timeout: TimeInterval? = nil) async throws -> CommandResult {
        current = arguments.first ?? "git"
        defer { current = nil }
        var attempt = 0
        while true {
            let result = try await Shell.run("git",
                                             baseArguments + arguments,
                                             cwd: root,
                                             extraEnv: env,
                                             timeout: timeout)
            if result.ok { return result }
            guard attempt < lockRetries, GitFailure.isLockContention(result.stderr) else {
                return result
            }
            attempt += 1
            try? await Task.sleep(nanoseconds: UInt64(attempt) * 200_000_000)
        }
    }
}
