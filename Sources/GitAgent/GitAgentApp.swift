import AppKit
import SwiftUI

@main
struct GitAgentApp: App {
    @StateObject private var workspace = Workspace()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Git Agent", id: "main") {
            RootView()
                .environmentObject(workspace)
                .environmentObject(workspace.settings)
                .task { await workspace.restore() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 396, height: 700)
        .commands { AppCommands(workspace: workspace, settings: workspace.settings) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// MARK: - Keyboard shortcuts

struct AppCommands: Commands {
    @ObservedObject var workspace: Workspace
    @ObservedObject var settings: AppSettings

    var body: some Commands {
        // Replaces the item the Settings scene used to provide, and opens a
        // window this app owns rather than one a private selector might find.
        CommandGroup(replacing: .appSettings) {
            Button("Settings\u{2026}") {
                Task { @MainActor in AppActions.openSettings() }
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(replacing: .newItem) {
            Button("Open Project\u{2026}") {
                Task { @MainActor in workspace.chooseProject() }
            }
            .keyboardShortcut("o", modifiers: .command)

            Menu("Open Recent") {
                ForEach(workspace.recentProjects, id: \.self) { path in
                    Button((path as NSString).lastPathComponent) {
                        Task { @MainActor in
                            await workspace.open(url: URL(fileURLWithPath: path, isDirectory: true))
                        }
                    }
                }
            }
            .disabled(workspace.recentProjects.isEmpty)
        }

        CommandMenu("Repository") {
            Button("Refresh") {
                Task { @MainActor in await workspace.active?.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(workspace.active == nil)

            Button("Switch Branch\u{2026}") {
                Task { @MainActor in workspace.active?.branchPickerOpen = true }
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(workspace.active?.repo == nil)

            Group {
                Button("Fetch from origin") {
                    Task { @MainActor in await workspace.active?.fetchRemote(silent: false) }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(workspace.active == nil
                          || workspace.active?.fetching == true
                          || workspace.active?.isBusy == true)

                Button("Sync & Pull") {
                    Task { @MainActor in workspace.active?.syncAndPull() }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(workspace.active?.repo == nil || workspace.active?.isBusy == true)

                Button("Pull (rebase)") {
                    Task { @MainActor in await workspace.active?.pull() }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(workspace.active?.repo?.upstream == nil || workspace.active?.isBusy == true)

                Button("Stash Changes") {
                    Task { @MainActor in await workspace.active?.stashChanges() }
                }
                .disabled(workspace.active?.repo?.hasChanges != true || workspace.active?.isBusy == true)
            }

            Button("Stage All Changes") {
                Task { @MainActor in await workspace.active?.stageAll() }
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(workspace.active?.repo?.hasChanges != true)

            Divider()

            Button("Commit") {
                Task { @MainActor in _ = await workspace.active?.commit() }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(workspace.active?.canCommit != true)

            Button("Commit & Push\u{2026}") {
                Task { @MainActor in await workspace.active?.commitAndPush() }
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(workspace.active?.canCommit != true)

            Button("Push\u{2026}") {
                Task { @MainActor in workspace.active?.requestPush() }
            }
            .disabled(workspace.active == nil)

            Group {
                Divider()

                Button("Close Project") {
                    Task { @MainActor in workspace.closeActive() }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(workspace.active == nil)
            }
        }

        CommandMenu("Agent") {
            Button("Ask the Agent\u{2026}") {
                Task { @MainActor in workspace.active?.openChat() }
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(workspace.active?.repo == nil)

            Divider()

            Button("Review Changes") {
                Task { @MainActor in await workspace.active?.reviewChanges() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(workspace.active?.repo?.hasChanges != true || workspace.active?.isBusy == true)

            Button("Generate Commit Message") {
                Task { @MainActor in await workspace.active?.generateCommitMessage() }
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(workspace.active?.repo?.hasChanges != true || workspace.active?.isBusy == true)

            Divider()

            Button("Cancel Agent") {
                Task { @MainActor in workspace.active?.cancelAgent() }
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(workspace.active?.agentBusyLabel == nil)
        }

        CommandGroup(after: .toolbar) {
            Button(settings.floatOnTop ? "Stop Floating on Top" : "Float on Top") {
                Task { @MainActor in settings.floatOnTop.toggle() }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Divider()

            // Grouped so the panel commands can grow without hitting the
            // ten-child limit of the commands builder.
            Group {
                Button("Search\u{2026}") {
                    Task { @MainActor in workspace.paletteOpen = true }
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(workspace.active?.repo == nil)

                Button("Show All Changes") {
                    Task { @MainActor in await workspace.active?.openAllChanges() }
                }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(workspace.active?.repo?.hasChanges != true)

                Button("Show Activity") {
                    Task { @MainActor in workspace.active?.openActivity() }
                }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(workspace.active == nil)

                Button("Show Stashes") {
                    Task { @MainActor in await workspace.active?.openStashes() }
                }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(workspace.active?.repo == nil)

                Button("Show Recovery") {
                    Task { @MainActor in await workspace.active?.openRecovery() }
                }
                .keyboardShortcut("4", modifiers: .command)
                .disabled(workspace.active?.repo == nil)

                Button("Reorganize Commits") {
                    Task { @MainActor in await workspace.active?.openRebase() }
                }
                .keyboardShortcut("5", modifiers: .command)
                .disabled(workspace.active?.repo == nil)

                Button("Show Pull Requests") {
                    Task { @MainActor in await workspace.active?.openForge() }
                }
                .keyboardShortcut("6", modifiers: .command)
                .disabled(workspace.active?.repo == nil)

                Button("Show Workflows") {
                    Task { @MainActor in workspace.active?.openWorkflows() }
                }
                .keyboardShortcut("7", modifiers: .command)
                .disabled(workspace.active?.repo == nil)

                Button("Close Panel") {
                    Task { @MainActor in workspace.active?.closeDetail() }
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(workspace.active?.detail == nil)
            }

            Divider()

            Button("Next Project") {
                Task { @MainActor in workspace.selectNext(1) }
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(workspace.tabs.count < 2)

            Button("Previous Project") {
                Task { @MainActor in workspace.selectNext(-1) }
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(workspace.tabs.count < 2)
        }
    }
}
