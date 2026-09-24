# Git Agent

A small, native macOS git client with the Cursor agent built in. Not an IDE: it
shows what changed, has the agent review it, fix it, and write the commit.

- SwiftUI + AppKit, Swift Package Manager, no Xcode project, no web view.
- Git through the `git` command line (porcelain v2), no libgit2.
- AI through the official Cursor CLI (`cursor-agent`) in headless mode.

## Icon

`Resources/AppIcon.icns` carries ten representations built from the brand
artwork: the mark alone up to 128pt, where a wordmark would be unreadable, and
the full logo at 256pt and 512pt. `build.sh` copies it into the bundle. The same
mark is drawn as vectors in `Views/BrandMark.swift` for the welcome screen, so it
stays crisp at any size. Brand orange is used for identity only — the state
colours (green, amber, red, blue) keep their meaning.

## Quick start

One command, on any Mac with macOS 13+:

```bash
curl -fsSL https://raw.githubusercontent.com/gabrielrcosta1/zeru-git/main/bootstrap.sh | bash
```

It installs the Xcode command line tools if they are missing, clones the source
into `~/.git-agent`, builds, installs the app, offers to install and log in to
the Cursor CLI, and opens it. Run the same command again to update.

Already cloned the repo? `./install.sh` does the same from there.

## Install

```bash
./install.sh            # builds release and installs to /Applications
./install.sh ~/Applications
./uninstall.sh
```

`install.sh` quits a running copy first (a bundle cannot be replaced while it
runs), copies with `ditto` so the signature survives, clears any stray
quarantine flag, and re-registers the app with Launch Services so Spotlight and
the Dock see it immediately. After that it is a normal Mac app: open it from
Spotlight, keep it in the Dock, no terminal involved. To update, run
`./install.sh` again.

## Build without installing

```bash
./build.sh              # release build + ./build/Git Agent.app
./build.sh debug        # debug build
open "build/Git Agent.app"
```

Requirements: macOS 13+, Xcode command line tools (`swift build`), `git`.

## A stable signature

Both scripts sign ad-hoc by default, which is enough to run the app but changes
its identity on every build. macOS keys privacy grants to that identity, so the
"Git Agent would like to access files on a removable volume" prompt comes back
after each rebuild, and System Settings fills up with duplicate entries.

To make the identity stable, create a self-signed code signing certificate once
— Keychain Access → Certificate Assistant → Create a Certificate, name it
`Git Agent Local`, identity type Self Signed Root, certificate type Code Signing
— then build with it:

```bash
export CODESIGN_IDENTITY="Git Agent Local"
./install.sh
```

Put that export in your shell profile and every build from then on is the same
app as far as macOS is concerned. A paid Apple Developer certificate is only
needed to hand the app to someone else's Mac without them right-clicking →
Open.

## Cursor CLI

The AI features shell out to the official CLI:

```bash
curl https://cursor.com/install -fsS | bash
cursor-agent login
```

Git Agent looks for `cursor-agent` (then `agent`) in `PATH`, `~/.local/bin`,
`/opt/homebrew/bin` and `/usr/local/bin`. If it lives somewhere else, set the
path in Settings (⌘,). A `CURSOR_API_KEY` can be set there instead of logging in.

Every call is `cursor-agent -p "<prompt>" --output-format stream-json --force
--trust --workspace <project>`, so the agent always works inside the project
that is open in the window. Tool calls and assistant text are streamed into the
Activity tab as they happen.

## What works now (MVP)

| # | Feature |
|---|---------|
| 1 | Compact floating panel (396pt) that expands to ~940pt only while a detail panel is open; ⌘⇧T keeps it above other apps |
| 2 | Open Project (⌘O), recent projects, git root detection |
| 3 | Live FSEvents watching, no Refresh needed (⌘R forces one) |
| 4 | Change list: modified, added, deleted, renamed, untracked, conflict, +/− counts, per-file stage/unstage |
| 5 | Diff on demand: clicking a file opens it in the expanded panel, never on the first screen |
| 6 | Cursor Agent integration, streamed into the Activity tab |
| 7 | AI Review is the first thing on screen: idle / analyzing with steps / understood with issues / looks good, plus risk and suggestions |
| 8 | Fix with AI per problem, then "AI changed N files" and a refreshed diff |
| 9 | AI commit message (⌘⇧G), editable, copyable, regenerable |
| 10 | Commit (⌘↩) and Commit & Push (⌘⇧↩) with an explicit push confirmation |
| 11 | Conflicts: banner at the top, CURRENT / INCOMING side by side, Resolve with AI, then Apply Resolution (stages only, never commits) |
| 12 | Explicit selection: checkboxes (with a mixed state) are the commit set, the button says "Commit 3 files" |
| 13 | Row hover actions: view diff, open the file in its editor, discard the change (always confirmed) |

Not built yet: test running, git history browser, menu bar item, auto commit,
contextual chat. The prompts for test-failure fixing and chat are already in
`Cursor/CursorPrompts.swift`.

## Several projects

Each open project is a tab with a session of its own: its own repository, file
watcher, Cursor agent, review, commit message and detail panel. Nothing is
shared between them except the app settings.

The tab strip only appears when more than one project is open, so a single
project looks exactly as it did before. A tab shows the project initial, its
name, the number of changes, and a dot when it needs attention (blue: commits
not pushed, red: a conflict). Background tabs keep watching their folders and
keep their counters live, but only the tab in front computes diffs.

Open another project with the `+` in the title strip or ⌘O; ⌘⇧] and ⌘⇧[ move
between them; ⌘⇧W closes the current one. Reopening a project that is already
open just brings its tab forward, and the open tabs come back on the next
launch.

## Window modes

The window is a compact panel by default and widens itself only while a detail
panel is open (a file diff, an issue, a conflict, the activity log). Closing the
panel with ⌘0 shrinks it back.

Resizing by hand wins: the app only changes the width when the mode actually
changes, and it remembers the width you chose for each mode (drag, zoom button
or a menu command), so it never undoes your resize on the next commit or tab
switch. Everything else lives in one scrolling column:
project, change totals, AI Review, changes, commit.

## The flow

The window follows one line: repository, changes, review, commit, push. The
button at the bottom right is always the next thing the repository is asking
for, and nothing else claims to be primary:

| State | Button |
|---|---|
| Changes in the tree | Commit & Push (with a plain Commit next to it) |
| Only commits ahead | Push N commits |
| Conflicts | N conflicts to resolve (disabled, the banner has the action) |
| Clean and in sync | Up to date (disabled) |

When it cannot run it says why in one line ("Write or generate a message",
"Tick the files to include") instead of sitting there dead.

Clicking a file expands its diff **in place**, under the row — no navigation, and
the list keeps its scroll position. One file at a time, so a long list stays
cheap; the side panel is still there for a bigger read, an AI finding, a conflict
or the activity log.

The secondary git commands live in the `⋯` menu and nowhere else: Fetch, Pull
(rebase), Push, Stash changes, Pop stash, and Abort rebase while a rebase is in
progress. Pull refuses on a dirty tree and points at Stash instead of stashing
behind your back; the stash never drops anything.

## Pull that resolves its own conflicts

Pull runs `git pull --rebase`. When it stops on a conflict, that is not reported
as an error: with "Resolve pull conflicts with AI" on (Settings, default on) the
app hands every conflicted file to the agent and then does the part the agent is
not allowed to do:

1. the agent reads each conflicted file, keeps both intents and writes the file
   back without markers — it is told not to run any git command;
2. Git Agent reads the files from disk and checks that no `<<<<<<<`, `|||||||`
   or `>>>>>>>` is left. An unreadable file (a binary conflict) counts as
   unresolved;
3. only then it stages them and runs `git rebase --continue`;
4. if the next replayed commit conflicts too, it goes round again, up to eight
   times.

It stops at the first thing it cannot verify and hands the repository back with
the reason, still mid-rebase, where `⋯ → Abort rebase` returns everything to
where it started. Cancel stops the loop between rounds. `GIT_EDITOR` is disabled
for every command the app runs, so a rebase can never sit waiting on an editor.

## AI Review findings

The agent reports what it verified, not only what is wrong: each finding carries
a kind, so a clean review says something. Passing checks are quiet grey lines
with a green check, issues are clickable and open in the panel with Fix with AI.
The headline counts issues, never the passing checks.

```
AI REVIEW                                    risk medium
⚠ 2 issues found
Added external service integration.
⚠ Possible N+1 query        JobService.php:42
✓ No breaking changes in the public API
✓ Migration matches the model
```

## Switching branches

The branch chip under the project name opens the branch picker (⌘B), which also
creates branches (New Branch, from the current HEAD): local
branches first, then the ones that exist only on a remote, most recently
committed first, with a filter because a repository can have a thousand refs
(the list shows the 40 newest until you type). A remote-only branch is checked
out as a new local branch tracking it. The picker has its own fetch button, so
branches someone else pushed show up without waiting for the automatic fetch.

Switching uses `git switch`, which carries uncommitted changes over and
**refuses** when a file would be overwritten — there is no force option in the
app. Switching is blocked while a conflict, a merge or a rebase is in progress,
and the review, the open diff and any push failure are cleared afterwards since
they belonged to the previous HEAD.

## Staying in sync

The app fetches `origin` when a project opens and every three minutes after
that (⌘⇧F to force one), so the ahead/behind counters are real. That is what
makes the push honest: the confirmation dialog says how many commits are about
to go out, and when the remote has moved ahead it says the push will be rejected
and gives the exact `git pull --rebase` line instead.

A commit that has not been pushed stays visible in the commit footer
("1 commit not pushed · Push"), and a failed push keeps its reason right there
with a Retry, so a push that did not happen can never look like one that did.
Push and fetch run with a timeout and their own queue, and while either is
running the window says so with the elapsed seconds.

## When git is busy

Every git invocation for the open repository is serialized through one queue
(`Core/GitRunner.swift`), so the app can never collide with itself, and every
command that writes the index has a timeout, so nothing can hold the lock
forever.

When `.git/index.lock` is in the way, the failing command is retried three times
with a short backoff. If the lock is still there, the app names the culprit
instead of saying "something": `lsof -w -Fp` gives the pids, `ps` gives their
names, and the process tree says whether they belong to Git Agent. That decides
what the dialog offers:

| Who holds it | What you get |
|---|---|
| Nobody, and the lock is old | Remove Lock File |
| A process Git Agent started (a pre-commit hook, usually) | Stop It & Retry — SIGTERM to that process only, then the lock is cleared |
| Another app (GitButler, an editor, a terminal) | Its name and pid, so you can close it. The app will not remove a lock someone else is holding |
| The check itself failed | It says so and removes nothing — an unknown holder is never treated as no holder |

The agent is told never to run git itself, since a second git process is the
usual source of the collision.

Other failures are translated too: missing `user.email`, nothing staged,
authentication, non-fast-forward, rejected hooks, unmerged paths, unreachable
remote. Every failure is logged in Activity with the git command that produced it.

## Safety

- The only destructive action is "Discard changes" in a row's hover actions, and
  it always asks first: tracked files are restored with `git restore` for that
  single path, and files that are not in any commit yet are moved to the Trash
  (recoverable) instead of deleted. Everything else the app runs is `add`,
  `restore --staged`, `commit -F`, `push` and read commands. `reset --hard`,
  `clean`, `checkout`, `rebase` and any `--force` push are not in the codebase.
- Push always asks for confirmation and shows the branch and the commit.
- Committing is blocked while a conflict is unresolved.
- `.env` files, keys, certificates and credential-looking paths are marked with
  a lock in the list and their diffs are never sent to the agent; the file name
  and status still are.
- The agent runs with `--force`, which is what makes headless mode possible: it
  can edit files and run commands inside the project without prompting. The
  prompts tell it not to run git write commands, but that is an instruction,
  not a sandbox. Review what the Activity tab reports.

## Layout

```
Sources/GitAgent/
  GitAgentApp.swift        app entry, menus, keyboard shortcuts
  Core/Shell.swift         process runner (collect + line stream)
  Core/GitModels.swift     FileChange, RepoState, sensitive-file rules
  Core/GitRepository.swift git status/diff/log/stage/commit/push
  Core/DiffParser.swift    unified diff -> hunks and lines
  Core/FileWatcher.swift   FSEvents with debounce and .git filtering
  Cursor/CursorAgent.swift cursor-agent process + stream-json parsing
  Cursor/CursorPrompts.swift every prompt sent to the agent
  Cursor/AIModels.swift    review model + tolerant JSON extraction
  ViewModel/Workspace.swift   the open tabs, the window, app-wide settings
  ViewModel/ProjectSession.swift  one project: orchestration and phases
  ViewModel/AppSettings.swift  settings shared by every tab
  Views/Theme.swift        design tokens and the shared small components
  Views/RootView.swift     window shell, tabs, compact column + detail panel
  Views/TabBar.swift       the project tabs
  Views/HeaderView.swift   title strip, project block, actions menu
  Views/AIReviewCard.swift summary strip, conflict banner, AI review states
  Views/ChangesSection.swift  selectable change list
  Views/CommitFooter.swift commit message and actions
  Views/DetailPanel.swift  diff / issue / activity panel
  Views/ConflictPanel.swift  current, incoming, AI resolution
```

## Shortcuts

| Action | Shortcut |
|---|---|
| Open project (new tab) | ⌘O |
| Next / previous project | ⌘⇧] / ⌘⇧[ |
| Close project (tab) | ⌘⇧W |
| Refresh | ⌘R |
| Switch branch | ⌘B |
| Pull (rebase) | ⌘⇧P |
| Stage All | ⌘⇧A |
| Review Changes | ⌘⇧R |
| Generate Commit Message | ⌘⇧G |
| Commit | ⌘↩ |
| Commit & Push | ⌘⇧↩ |
| Cancel Agent | ⌘. |
| Float on Top | ⌘⇧T |
| Show all changes | ⌘1 |
| Show activity | ⌘2 |
| Close detail panel | ⌘0 |
| Settings | ⌘, |
