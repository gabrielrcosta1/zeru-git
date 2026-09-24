import Foundation

enum CursorPrompts {

    /// Hard cap on inline diff characters sent to the agent.
    static let diffBudget = 90_000

    /// True while the provider in use can open files. An API answers with
    /// text, and telling it to "read the files" invites it to invent what it
    /// could not see.
    static var canReadFiles = true

    static func truncate(_ diff: String) -> (text: String, truncated: Bool) {
        guard diff.count > diffBudget else { return (diff, false) }
        let cut = String(diff.prefix(diffBudget))
        let tail = canReadFiles
            ? "\n... diff truncated, read the files directly if you need more ..."
            : "\n... diff truncated here, and there is no more of it ..."
        return (cut + tail, true)
    }

    static func fileList(_ state: RepoState) -> String {
        if state.changes.isEmpty { return "  (no changes)" }
        return state.changes.map { change -> String in
            var line = "  \(change.status.badge) \(change.path) (+\(change.additions)/-\(change.deletions))"
            if change.staged && change.unstaged {
                line += " [staged + unstaged]"
            } else if change.staged {
                line += " [staged]"
            }
            if change.isSensitive { line += " [sensitive: diff withheld]" }
            return line
        }.joined(separator: "\n")
    }

    private static func context(_ state: RepoState, diff: String) -> String {
        let budgeted = truncate(diff)
        var text = """
        Repository: \(state.root.path)
        Branch: \(state.branchLabel)\(state.upstream.map { " (upstream \($0))" } ?? " (no upstream)")
        Merge in progress: \(state.isMerging ? "yes" : "no")
        Conflicted files: \(state.conflicts.isEmpty ? "none" : state.conflicts.map { $0.path }.joined(separator: ", "))

        Changed files:
        \(fileList(state))

        Unified diff of the uncommitted changes:
        ```diff
        \(budgeted.text)
        ```
        """
        if budgeted.truncated {
            text += canReadFiles
                ? "\n\nThe diff above was truncated. Use your file tools to read whatever else you need."
                : "\n\nThe diff above was truncated and you cannot read the files. Judge only what you can see, and say so where the diff runs out rather than guessing."
        }
        return text
    }

    /// What the app will and will not let a proposed command be. Shared by
    /// every prompt that asks for git commands: two copies of this list would
    /// drift, and the drifted one would send the model at a refused command.
    static let commandRules = """
    Rules, and they are not negotiable:
    - Do NOT run any command yourself. Do not use your terminal. Propose, and stop.
    - Do NOT modify, create or delete any file. This is git only.
    - Every command must be plain git, given as a list of arguments, with no shell in it:
      no pipes, no redirection, no &&, no quoting, no environment variables.

    The app runs each command itself and checks it against an allowlist first. This is the
    whole list, and anything outside it is refused and skipped:

      runs straight away (reads nothing but the repository):
        status, log, show, diff, rev-parse, rev-list, merge-base, cherry, describe,
        name-rev, shortlog, ls-files, for-each-ref, reflog, stash list, stash show
      runs straight away (changes things, loses nothing):
        add, commit -m, stash push, stash apply, stash pop, stash branch,
        switch (including -c), branch (create, or -m to rename), fetch <remote>,
        rebase --continue, merge --continue, merge --quit, cherry-pick, revert
      stops and waits for the user to confirm that exact command:
        reset --keep, reset --soft, reset --mixed, stash drop, stash clear, push,
        pull (--rebase, --no-rebase, --ff-only, --autostash), merge <branch>
        (--no-ff, --ff-only, --no-edit, -m), rebase <upstream>
        (--onto, --autostash), rebase --abort, rebase --skip, merge --abort,
        cherry-pick --abort, revert --abort

    So yes: pulling, merging and starting a rebase are things you can propose. They stop and
    show the user the exact command first, which is the whole point. Never tell the user to
    go and run git in a terminal because this app cannot do it \u{2014} say what you would run,
    and let them press the button.

    Refused, so do not propose them: checkout, restore, reset --hard, clean, mv, rm, tag,
    notes, apply, am, config, remote, submodule, symbolic-ref, grep, cat-file, gc, and
    anything not named above. Also refused, whatever the subcommand: any -f, --force,
    --force-with-lease or --force-create flag; a push or pull refspec (write
    ["push", "origin", "main"], never ["push", "origin", "+main:main"]); --output=;
    --ext-diff; -p or --patch on log, show or diff; -i or --interactive; merge --squash;
    an option written as --flag=value on pull, merge or rebase (write
    ["rebase", "--onto", "main"], never ["rebase", "--onto=main"]); commit --amend;
    commit -a; and a remote given as a path rather than a name (["pull", "origin", "main"],
    never ["pull", "../other-clone", "main"]).

    Every short option is exactly two characters and stands alone: write ["log", "-n", "5"],
    never ["log", "-n5"], and never ["push", "-uf", ...]. Anything longer than two characters
    after a single dash is refused, because git would read it as several options at once.
    """

    // MARK: - Fixing a git failure

    /// Hands one failure to the agent and asks for a plan, not an action.
    ///
    /// The agent does not run git here. It proposes commands, the app checks
    /// every one of them against its own allowlist, and anything that can
    /// destroy work waits for the user. Saying so in the prompt keeps the plan
    /// inside what will actually be allowed to run.
    static func fixGitFailure(failure: AIFailure,
                              state: RepoState,
                              reflog: [ReflogEntry],
                              stashes: [GitStashEntry]) -> String {
        let recentReflog = reflog.prefix(8).map { entry in
            "  \(entry.selector) \(entry.shortOld) \u{2192} \(entry.shortSha)  \(entry.action): \(entry.message)"
        }.joined(separator: "\n")

        let stashList = stashes.isEmpty
            ? "  (empty)"
            : stashes.prefix(6).map { "  \($0.ref) \($0.title) [\($0.shortSha)]" }.joined(separator: "\n")

        let commits = state.recentCommits.prefix(6).map {
            "  \($0.shortSha) \($0.subject)"
        }.joined(separator: "\n")

        return """
        You are the git troubleshooter of a small macOS git client. One git command failed.
        Work out why, and propose the shortest sequence of git commands that gets the user
        out of it without losing any of their work.

        What failed:
          command: \(failure.commandLabel)
          the app told the user: \(failure.message)
          git's own output:
        ```
        \(String(failure.raw.prefix(4000)))
        ```

        Repository: \(state.root.path)
        Branch: \(state.branchLabel)\(state.upstream.map { " (upstream \($0), ahead \(state.ahead), behind \(state.behind))" } ?? " (no upstream)")
        Merge in progress: \(state.isMerging ? "yes" : "no")
        Rebase in progress: \(state.isRebasing ? "yes" : "no")
        Conflicted files: \(state.conflicts.isEmpty ? "none" : state.conflicts.map { $0.path }.joined(separator: ", "))
        Uncommitted changes (\(state.changes.count)):
        \(fileList(state))

        Recent commits:
        \(commits.isEmpty ? "  (none)" : commits)

        Branch reflog (newest first), which is the way back from anything:
        \(recentReflog.isEmpty ? "  (unavailable)" : recentReflog)

        Stash:
        \(stashList)

        \(commandRules)

        - Anything in the third group will stop and wait. Propose it if it is right, and say
          plainly in "why" what it costs.
        - The user's uncommitted work matters more than a tidy history. When in doubt,
          stash push it and say so.
        - A commit that is only unreachable is not lost: it is in the reflog, and the app has a
          Recovery panel built for exactly that. If that is the fix, say so in the diagnosis
          instead of proposing a reset the user does not need.
        - Keep it to the fewest steps that actually fix it. Five is a lot.

        Answer with a single JSON object and nothing else. No prose, no markdown fences.

        {
          "diagnosis": "two or three sentences: what went wrong and why, in plain words",
          "steps": [
            {
              "command": ["stash", "push", "--include-untracked", "-m", "before moving the branch"],
              "why": "one sentence: what this does and what it costs"
            }
          ],
          "note": "anything the user should know afterwards, or an empty string"
        }
        """
    }

    // MARK: - The plan that did not work

    /// Hands the agent back its own plan, with what git said to each command.
    ///
    /// Without this the user reads a failure on screen that the agent cannot
    /// see, and the only way forward is retyping git's output by hand.
    static func retryPlan(previous: GitCommandPlan,
                          question: String?,
                          failure: AIFailure?,
                          state: RepoState,
                          reflog: [ReflogEntry],
                          stashes: [GitStashEntry]) -> String {
        let attempts = previous.steps.enumerated().map { pair -> String in
            let step = pair.element
            var line = "  \(pair.offset + 1). \(step.display)\n"
            switch step.outcome {
            case .pending:
                line += "     never ran"
            case .running:
                line += "     was still running"
            case .done(let output):
                let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
                line += "     worked" + (text.isEmpty ? "" : ":\n" + indent(text))
            case .failed(let output):
                line += "     FAILED:\n" + indent(output)
            case .skipped(let why):
                line += "     skipped: \(why)"
            }
            return line
        }.joined(separator: "\n")

        let recentReflog = reflog.prefix(6).map { entry in
            "  \(entry.selector) \(entry.shortOld) \u{2192} \(entry.shortSha)  \(entry.action): \(entry.message)"
        }.joined(separator: "\n")

        let stashList = stashes.isEmpty
            ? "  (empty)"
            : stashes.prefix(6).map { "  \($0.ref) \($0.title) [\($0.shortSha)]" }.joined(separator: "\n")

        let asked = question.map { "What the developer asked for: \($0)\n" } ?? ""
        let original = failure.map { "The failure this started from: \($0.commandLabel) \u{2014} \($0.message)\n" } ?? ""

        return """
        You are the git troubleshooter of a small macOS git client. You proposed a plan, the
        app ran it, and it did not work. Here is exactly what happened. Work out why, and
        propose a new plan.

        \(asked)\(original)
        Your diagnosis was: \(previous.diagnosis.isEmpty ? "(none)" : previous.diagnosis)

        What ran, and what git said:
        \(attempts.isEmpty ? "  (nothing ran)" : attempts)

        The repository as it stands NOW, after all of that:
        Branch: \(state.branchLabel)\(state.upstream.map { " (upstream \($0), ahead \(state.ahead), behind \(state.behind))" } ?? " (no upstream)")
        Detached HEAD: \(state.detached ? "yes" : "no")
        Merge in progress: \(state.isMerging ? "yes" : "no")
        Rebase in progress: \(state.isRebasing ? "yes" : "no")
        Conflicted files: \(state.conflicts.isEmpty ? "none" : state.conflicts.map { $0.path }.joined(separator: ", "))
        Uncommitted changes (\(state.changes.count)):
        \(fileList(state))

        Branch reflog (newest first):
        \(recentReflog.isEmpty ? "  (unavailable)" : recentReflog)

        Stash:
        \(stashList)

        \(commandRules)

        - Read the error text above before proposing anything. A command that failed for a
          reason that is still true will fail again.
        - A file that git says is untracked and in the way is not yours to delete: stash push
          takes untracked files with --include-untracked, and that is the way past it.
        - If a step failed because the repository is in a state your plan did not expect, say
          so plainly in the diagnosis instead of repeating the same command.
        - If there is genuinely nothing this app is allowed to run that fixes it, say that in
          the diagnosis and leave "steps" empty. An honest dead end beats a refused command.

        Answer with a single JSON object and nothing else. No prose, no markdown fences.

        {
          "diagnosis": "what actually went wrong this time, in plain words",
          "steps": [
            {
              "command": ["stash", "push", "--include-untracked", "-m", "in the way of the rebase"],
              "why": "one sentence: what this does and what it costs"
            }
          ],
          "note": "anything the user should know afterwards, or an empty string"
        }
        """
    }

    private static func indent(_ text: String) -> String {
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(8)
            .map { "       " + $0 }
            .joined(separator: "\n")
    }

    // MARK: - Review

    static func review(state: RepoState, diff: String) -> String {
        return """
        You are the review engine of a small macOS git client. Review ONLY the uncommitted changes below.

        \(context(state, diff: diff))

        Rules:
        - Do NOT modify, create or delete any file in this task. Read only.
        - Judge the change as it is: look for bugs, incomplete edits, broken contracts between
          frontend and backend, obvious security problems, leaked secrets, and files that were
          changed in a way that probably breaks other callers.
        \(canReadFiles
          ? "- You may read other files in the repository to check whether callers break."
          : "- You cannot open files: judge only the diff below, and where a caller might break but you cannot see it, say so instead of assuming either way.")
        - Never quote secret values. If a secret appears in the diff, report it as a problem
          without repeating the value.

        Answer with a single JSON object and nothing else. No prose, no markdown fences.

        {
          "summary": "two or three sentences describing what these changes do",
          "risk": "low" | "medium" | "high",
          "findings": [
            {
              "kind": "ok" | "warning" | "risk",
              "title": "short title, one line",
              "file": "path/relative/to/repo",
              "line": 0,
              "severity": "low" | "medium" | "high",
              "detail": "what you found and why it matters"
            }
          ],
          "suggestions": ["short actionable suggestion"]
        }

        Rules for findings:
        - Report between 2 and 6 findings, ordered with the problems first.
        - Use "kind": "ok" for the checks that passed, phrased as a statement:
          "No breaking changes in the public API", "Migration matches the model",
          "Documentation matches the implementation". Only claim a check you
          actually verified in the diff or in the files around it.
        - Use "warning" for something suspicious and "risk" for something that
          will break. Set "file" and "line" whenever they apply, "line" 0 when not.
        - Never report a positive finding about a file you did not read.
        """
    }

    // MARK: - Fix

    static func fix(problem: AIProblem, state: RepoState, diff: String) -> String {
        return """
        You are working inside a real project with uncommitted changes. Fix exactly one problem.

        Problem: \(problem.title)
        Location: \(problem.location ?? "not specified")
        Detail: \(problem.detail)

        \(context(state, diff: diff))

        Rules:
        - Fix only this problem. Do not refactor unrelated code, do not reformat files,
          do not rename anything that was not part of the problem.
        - Keep the existing style and patterns of the project.
        - Do not run ANY git command, not even a read-only one. The app owns the
          repository state and runs git itself; a concurrent git process here would
          lock the index and break the app. Never run: git status, git add, git diff,
          git commit, git push, git reset, git clean, git checkout, git rebase.
        - Do not touch .env files, credentials or key material.
        - Edit the files directly with your tools.

        When you are done, reply with a short plain text report:
        line 1: one sentence describing the fix
        then one line per file you changed, in the form "changed: path/to/file"
        """
    }

    static func fixTestFailure(command: String, output: String, state: RepoState) -> String {
        let trimmed = output.count > 12_000 ? String(output.suffix(12_000)) : output
        return """
        The verification command below failed in \(state.root.path).

        Command: \(command)

        Output:
        ```
        \(trimmed)
        ```

        Changed files:
        \(fileList(state))

        Fix the cause of this failure. Keep the change minimal, do not refactor unrelated
        code, and do not run any git command at all: the app owns the repository state.

        When you are done, reply with a short plain text report:
        line 1: one sentence describing the fix
        then one line per file you changed, in the form "changed: path/to/file"
        """
    }

    // MARK: - Commit message

    static func commitMessage(state: RepoState, diff: String) -> String {
        return """
        Write the commit message for the staged changes of this repository.

        \(context(state, diff: diff))

        Rules:
        - Conventional Commits: type(optional scope): subject
        - Subject in imperative mood, lower case after the colon, no trailing period, max 72 characters.
        - Add a body only when the change is not obvious from the subject: one blank line, then
          up to three short bullet lines starting with "- ".
        - Never include secrets, tokens, keys, passwords, file contents or diff fragments.
        - Do not modify any file in this task.

        Output the commit message only. No fences, no quotes, no explanation.
        """
    }

    // MARK: - Conflict resolution

    static func resolveConflict(path: String, current: String?, incoming: String?, state: RepoState) -> String {
        let currentBlock = current.map { $0.count > 20_000 ? String($0.prefix(20_000)) : $0 } ?? "(unavailable)"
        let incomingBlock = incoming.map { $0.count > 20_000 ? String($0.prefix(20_000)) : $0 } ?? "(unavailable)"
        return """
        Resolve the git merge conflict in \(path) inside \(state.root.path).

        Current branch version (stage 2):
        ```
        \(currentBlock)
        ```

        Incoming version (stage 3):
        ```
        \(incomingBlock)
        ```

        Rules:
        - Keep the intent of both sides whenever they are compatible.
        - Write the resolved file to disk with your tools and remove every conflict marker.
        - Do not run any git command at all, not even a read-only one. The app owns the
          repository state and a concurrent git process would lock its index. The user
          stages and commits from the app.
        - Explain in one or two sentences what you kept from each side.
        """
    }

    /// Used by the pull flow: the files on disk still carry the markers, so the
    /// agent reads them itself instead of being fed both sides.
    static func resolveConflicts(paths: [String], state: RepoState) -> String {
        let list = paths.map { "  - " + $0 }.joined(separator: "\n")
        return """
        A pull left merge conflicts in \(state.root.path). Resolve every one of them.

        Conflicted files:
        \(list)

        Each of those files still contains the conflict markers. Read each file, understand
        what both sides were trying to do, and write the resolved version to disk.

        Rules:
        - Keep the intent of both sides whenever they are compatible. When they truly
          conflict, keep the incoming change and preserve any local behaviour that does
          not contradict it.
        - Remove every conflict marker. A file that still has one counts as unresolved.
        - Do not reformat or refactor anything beyond the conflicting regions.
        - Do not run any git command at all, not even a read-only one: the app owns the
          repository state and will stage and continue the rebase itself.
        - Do not touch .env files, credentials or key material.

        When you are done, reply with one short line per file:
        "resolved: <path> - <what you kept>"
        """
    }

    // MARK: - Chat

    /// The user asking for something in their own words.
    ///
    /// Same contract as the fix prompt: the agent answers, and proposes
    /// commands only when commands are the answer. It never runs them: the app
    /// classifies every one of them and the user presses Run.
    static func gitChat(question: String,
                        history: [String],
                        state: RepoState,
                        diff: String,
                        reflog: [ReflogEntry],
                        stashes: [GitStashEntry]) -> String {
        let recentReflog = reflog.prefix(6).map { entry in
            "  \(entry.selector) \(entry.shortOld) \u{2192} \(entry.shortSha)  \(entry.action): \(entry.message)"
        }.joined(separator: "\n")

        let stashList = stashes.isEmpty
            ? "  (empty)"
            : stashes.prefix(6).map { "  \($0.ref) \($0.title) [\($0.shortSha)]" }.joined(separator: "\n")

        let commits = state.recentCommits.prefix(8).map {
            "  \($0.shortSha) \($0.subject)"
        }.joined(separator: "\n")

        let earlier = history.isEmpty
            ? ""
            : """

        Earlier in this conversation, oldest first:
        \(history.joined(separator: "\n"))
        """

        return """
        You are the git assistant inside a small macOS git client. The developer asks for
        things in their own words. Answer the question, and when the answer is "run these git
        commands", propose them.

        \(context(state, diff: diff))
        Rebase in progress: \(state.isRebasing ? "yes" : "no")
        Ahead \(state.ahead), behind \(state.behind).

        Recent commits:
        \(commits.isEmpty ? "  (none)" : commits)

        Branch reflog (newest first), which is the way back from anything:
        \(recentReflog.isEmpty ? "  (unavailable)" : recentReflog)

        Stash:
        \(stashList)
        \(earlier)

        Question: \(question)

        \(commandRules)

        How to answer:
        - Short. Two or three sentences, no preamble, no "great question", no restating what
          the user asked. Say the thing.
        - Answer in the language the question was asked in.
        - Propose commands only when the user wants something done, or when the answer is a
          command they would have to type. A question about what happened is answered in
          words, with "steps" empty.
        - Never propose a command that is not on the list above. If what the user wants can
          only be done with a refused command, say so in one sentence and stop.
        - The user's uncommitted work matters more than a tidy history. When in doubt, stash
          push it and say so.
        - A commit that is only unreachable is not lost: it is in the reflog, and this app has
          a Recovery panel built for exactly that.
        - Fewest steps that actually do it. Five is a lot.

        Answer with a single JSON object and nothing else. No prose, no markdown fences.

        {
          "diagnosis": "the answer itself, in plain words",
          "steps": [
            {
              "command": ["switch", "-c", "feature/login"],
              "why": "one sentence: what this does and what it costs"
            }
          ],
          "note": "anything worth knowing afterwards, or an empty string"
        }
        """
    }
}
