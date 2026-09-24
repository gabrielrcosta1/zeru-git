import Foundation

// MARK: - Which host

enum ForgeKind: String, Hashable {
    case github
    case gitlab

    var name: String {
        switch self {
        case .github: return "GitHub"
        case .gitlab: return "GitLab"
        }
    }

    /// The command line tool the user already has authenticated. The app never
    /// stores a token of its own.
    var cli: String {
        switch self {
        case .github: return "gh"
        case .gitlab: return "glab"
        }
    }

    var requestName: String {
        switch self {
        case .github: return "pull request"
        case .gitlab: return "merge request"
        }
    }

    var loginHint: String {
        switch self {
        case .github: return "gh auth login"
        case .gitlab: return "glab auth login"
        }
    }
}

/// What the app knows about the hosting side of this repository.
struct ForgeInfo: Hashable {
    let kind: ForgeKind
    /// "owner/repo", best effort, from the remote URL.
    let slug: String
    let cliPath: String?
    let authenticated: Bool

    var hasCLI: Bool { return cliPath != nil }
    /// Only GitHub is read in detail: `gh --json` is a documented, stable
    /// interface. GitLab gets the actions that need no parsing.
    var readsDetail: Bool { return kind == .github && hasCLI && authenticated }
    var canOpen: Bool { return hasCLI && authenticated }
}

enum ForgeDetect {
    /// Works for both spellings git uses: scp-like (git@host:owner/repo.git)
    /// and URL (https://host/owner/repo.git, ssh://git@host/owner/repo).
    static func detect(remote url: String) -> (kind: ForgeKind, slug: String, host: String)? {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // A remote can carry a trailing slash on either side of the .git.
        while text.hasSuffix("/") { text = String(text.dropLast()) }
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        while text.hasSuffix("/") { text = String(text.dropLast()) }

        var host = ""
        var slug = ""

        if let scheme = text.range(of: "://") {
            var rest = String(text[scheme.upperBound...])
            // A user, or a user and a token, in front of the host.
            if let slash = rest.firstIndex(of: "/"),
               let at = rest[..<slash].lastIndex(of: "@") {
                rest = String(rest[rest.index(after: at)...])
            }
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = String(rest[..<slash])
            if let port = host.firstIndex(of: ":") { host = String(host[..<port]) }
            slug = String(rest[rest.index(after: slash)...])
        } else if let colon = text.firstIndex(of: ":") {
            let hostPart = String(text[..<colon])
            host = hostPart.split(separator: "@").last.map(String.init) ?? hostPart
            slug = String(text[text.index(after: colon)...])
        } else {
            return nil
        }

        guard let kind = kind(forHost: host) else { return nil }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // ssh://host/~owner/repo is the same repository as owner/repo.
        if slug.hasPrefix("~") { slug = String(slug.dropFirst()) }
        guard !slug.isEmpty else { return nil }
        return (kind, slug, host.lowercased())
    }

    private static func kind(forHost host: String) -> ForgeKind? {
        let lower = host.lowercased()
        if lower == "github.com" { return .github }
        if lower == "gitlab.com" { return .gitlab }
        // A self-hosted instance usually carries the name as one whole label:
        // gitlab.example.com, github.acme.internal. Matching a substring
        // instead would claim github-mirror.example.com, which it is not.
        let labels = lower.split(separator: ".").map(String.init)
        if labels.contains("github") { return .github }
        if labels.contains("gitlab") { return .gitlab }
        return nil
    }
}

/// Where this repository lives on the web.
///
/// Built from the remote alone: opening a page needs no CLI and no login, so
/// this works in a repository where `gh` was never installed.
struct ForgeWeb: Hashable {
    let kind: ForgeKind
    /// "owner/repo".
    let slug: String
    /// The host as the remote spells it, so a self-hosted instance works too.
    let host: String

    enum Page: Hashable {
        case repo
        case branch(String)
        case commits(String)
        case requests
        case actions
    }

    static func from(remote: String?) -> ForgeWeb? {
        guard let remote, let found = ForgeDetect.detect(remote: remote) else { return nil }
        return ForgeWeb(kind: found.kind, slug: found.slug, host: found.host)
    }

    private var base: String { return "https://\(host)/\(slug)" }

    func url(for page: Page) -> URL? {
        // GitLab puts "/-/" in front of everything below the repository root so
        // a branch called "tree" cannot collide with a route.
        let infix = kind == .gitlab ? "/-" : ""
        var text = base
        switch page {
        case .repo:
            break
        case .branch(let name):
            guard let escaped = escape(name) else { return URL(string: base) }
            text += "\(infix)/tree/\(escaped)"
        case .commits(let name):
            guard let escaped = escape(name) else { return URL(string: base) }
            text += "\(infix)/commits/\(escaped)"
        case .requests:
            text += kind == .github ? "/pulls" : "/-/merge_requests"
        case .actions:
            text += kind == .github ? "/actions" : "/-/pipelines"
        }
        return URL(string: text)
    }

    /// A branch name can hold anything git allows, and "feature/a b" in a path
    /// is not a URL.
    private func escape(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        return trimmed.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    func label(for page: Page) -> String {
        switch page {
        case .repo: return "Repository on \(kind.name)"
        case .branch: return "This branch on \(kind.name)"
        case .commits: return "Commits on \(kind.name)"
        case .requests: return "\(kind.requestName.capitalized)s on \(kind.name)"
        case .actions: return kind == .github ? "Actions on GitHub" : "Pipelines on GitLab"
        }
    }
}

// MARK: - What comes back

struct ForgeChecks: Hashable {
    var passed = 0
    var failed = 0
    var pending = 0

    var total: Int { return passed + failed + pending }
    var isEmpty: Bool { return total == 0 }
    var isFailing: Bool { return failed > 0 }
    var isRunning: Bool { return failed == 0 && pending > 0 }

    /// "3 passed", "1 failed \u{00b7} 2 running", nil when there are no checks.
    var label: String? {
        guard !isEmpty else { return nil }
        var parts: [String] = []
        if failed > 0 { parts.append("\(failed) failed") }
        if pending > 0 { parts.append("\(pending) running") }
        if passed > 0 { parts.append("\(passed) passed") }
        return parts.joined(separator: " \u{00b7} ")
    }
}

struct ForgePullRequest: Identifiable, Hashable {
    let number: Int
    let title: String
    /// "OPEN", "MERGED", "CLOSED".
    let state: String
    let isDraft: Bool
    let url: String
    let branch: String
    /// "APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED", or nil.
    let reviewDecision: String?
    let checks: ForgeChecks

    var id: Int { return number }
    var isOpen: Bool { return state == "OPEN" }

    var stateLabel: String {
        if isDraft && isOpen { return "draft" }
        return state.lowercased()
    }

    var reviewLabel: String? {
        switch reviewDecision {
        case "APPROVED": return "approved"
        case "CHANGES_REQUESTED": return "changes requested"
        case "REVIEW_REQUIRED": return "review required"
        default: return nil
        }
    }
}

struct ForgeIssue: Identifiable, Hashable {
    let number: Int
    let title: String
    let url: String

    var id: Int { return number }
}

// MARK: - The client

/// Talks to the host through the CLI the user already has authenticated.
///
/// The app stores no token and holds no credential: if `gh` is not installed,
/// or not logged in, nothing here happens at all and the panel says so.
struct ForgeClient {
    let root: URL
    let info: ForgeInfo

    /// Detects the host from origin, and whether its CLI is there and logged in.
    static func detect(root: URL, remote: String?) async -> ForgeInfo? {
        guard let remote, let found = ForgeDetect.detect(remote: remote) else { return nil }
        let cli = Shell.which(found.kind.cli)
        var authenticated = false
        if let cli {
            // Both CLIs exit non-zero when there is no login.
            if let result = try? await Shell.run(cli, ["auth", "status"], cwd: root, timeout: 20) {
                authenticated = result.ok
            }
        }
        return ForgeInfo(kind: found.kind, slug: found.slug, cliPath: cli, authenticated: authenticated)
    }

    private func run(_ arguments: [String], timeout: TimeInterval) async -> CommandResult? {
        guard let cli = info.cliPath else { return nil }
        return try? await Shell.run(cli, arguments, cwd: root, timeout: timeout)
    }

    /// The open pull request for one branch, with its checks.
    ///
    /// `pr list --head` rather than `pr view <branch>`: `pr view` also accepts
    /// a number, so a branch called "123" would show pull request #123, and it
    /// answers with a merged request when no open one exists.
    ///
    /// A nil request with a nil problem means there is none. A problem means
    /// the read did not work, which is not the same thing and must not be
    /// shown as "no pull request".
    func pullRequest(forBranch branch: String) async -> (request: ForgePullRequest?, problem: String?) {
        guard info.readsDetail, !branch.isEmpty else { return (nil, nil) }
        let fields = "number,title,state,isDraft,url,headRefName,reviewDecision,statusCheckRollup"
        let arguments = ["pr", "list", "--head", branch, "--state", "open",
                         "--limit", "1", "--json", fields]
        guard let result = await run(arguments, timeout: 30) else {
            return (nil, "Could not run \(info.kind.cli).")
        }
        guard result.ok else { return (nil, ForgeClient.problem(from: result, cli: info.kind.cli)) }
        guard let data = result.stdout.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return (nil, "\(info.kind.cli) answered with something this version cannot read.")
        }
        return (array.compactMap { ForgeClient.pullRequest(from: $0) }.first, nil)
    }

    /// Open pull requests, without their checks: a rollup per request is a
    /// request per request, and this list is context, not the main event.
    func pullRequests(limit: Int) async -> (requests: [ForgePullRequest], problem: String?) {
        guard info.readsDetail else { return ([], nil) }
        let fields = "number,title,state,isDraft,url,headRefName"
        guard let result = await run(["pr", "list", "--limit", "\(limit)", "--json", fields],
                                     timeout: 30) else {
            return ([], "Could not run \(info.kind.cli).")
        }
        guard result.ok else { return ([], ForgeClient.problem(from: result, cli: info.kind.cli)) }
        guard let data = result.stdout.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return ([], "\(info.kind.cli) answered with something this version cannot read.")
        }
        return (array.compactMap { ForgeClient.pullRequest(from: $0) }, nil)
    }

    func issues(limit: Int) async -> (issues: [ForgeIssue], problem: String?) {
        guard info.readsDetail else { return ([], nil) }
        guard let result = await run(["issue", "list", "--assignee", "@me",
                                      "--limit", "\(limit)", "--json", "number,title,url"],
                                     timeout: 30) else {
            return ([], "Could not run \(info.kind.cli).")
        }
        guard result.ok else { return ([], ForgeClient.problem(from: result, cli: info.kind.cli)) }
        guard let data = result.stdout.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return ([], "\(info.kind.cli) answered with something this version cannot read.")
        }
        let issues: [ForgeIssue] = array.compactMap { entry in
            guard let number = entry["number"] as? Int else { return nil }
            return ForgeIssue(number: number,
                              title: entry["title"] as? String ?? "",
                              url: entry["url"] as? String ?? "")
        }
        return (issues, nil)
    }

    /// What went wrong, in the CLI's own words.
    private static func problem(from result: CommandResult, cli: String) -> String {
        let text = (result.stderr.isEmpty ? result.stdout : result.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "\(cli) exited with status \(result.status)." : text
    }

    /// Opens the create form in the browser, prefilled from the commits.
    ///
    /// Nothing is published from inside the app: the title, the base branch and
    /// the reviewers are decisions, and the web form is where the user already
    /// makes them.
    func openCreateForm() async -> String? {
        guard info.canOpen else { return nil }
        let arguments = info.kind == .github
            ? ["pr", "create", "--web", "--fill"]
            : ["mr", "create", "--web", "--fill"]
        guard let result = await run(arguments, timeout: 45) else { return "Could not run \(info.kind.cli)." }
        guard result.ok else {
            let text = result.stderr.isEmpty ? result.stdout : result.stderr
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// GitLab's equivalent of opening the request for this branch, which needs
    /// no JSON parsing.
    func openRequestInBrowser() async -> String? {
        guard info.canOpen else { return nil }
        let arguments = info.kind == .github ? ["pr", "view", "--web"] : ["mr", "view", "--web"]
        guard let result = await run(arguments, timeout: 45) else { return "Could not run \(info.kind.cli)." }
        guard result.ok else {
            let text = result.stderr.isEmpty ? result.stdout : result.stderr
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // MARK: Decoding

    /// Hand decoded rather than Codable: a field can be null, and a shape can
    /// gain a key, without the whole row disappearing.
    private static func pullRequest(from object: [String: Any]) -> ForgePullRequest? {
        guard let number = object["number"] as? Int else { return nil }

        var checks = ForgeChecks()
        if let rollup = object["statusCheckRollup"] as? [[String: Any]] {
            for entry in rollup {
                // A check run reports "conclusion"; an old style commit status
                // reports "state". Anything still going reports neither.
                let verdict = ((entry["conclusion"] as? String)
                               ?? (entry["state"] as? String)
                               ?? "").uppercased()
                switch verdict {
                case "SUCCESS", "NEUTRAL", "SKIPPED":
                    checks.passed += 1
                case "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE":
                    checks.failed += 1
                default:
                    checks.pending += 1
                }
            }
        }

        let decision = (object["reviewDecision"] as? String) ?? ""
        return ForgePullRequest(number: number,
                                title: object["title"] as? String ?? "",
                                state: (object["state"] as? String ?? "").uppercased(),
                                isDraft: object["isDraft"] as? Bool ?? false,
                                url: object["url"] as? String ?? "",
                                branch: object["headRefName"] as? String ?? "",
                                reviewDecision: decision.isEmpty ? nil : decision,
                                checks: checks)
    }
}
