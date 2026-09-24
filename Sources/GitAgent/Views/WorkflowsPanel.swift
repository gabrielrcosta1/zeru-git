import SwiftUI

/// The library. One row per workflow, and nothing that is not a workflow.
struct WorkflowsPanel: View {
    @EnvironmentObject private var state: ProjectSession
    @State private var pendingDelete: GitWorkflow?

    private var engine: WorkflowEngine { return state.workflows }

    var body: some View {
        VStack(spacing: 0) {
            content
            Hairline()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await engine.load() }
        .alert("Delete this workflow?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { workflow in
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                let doomed = workflow
                pendingDelete = nil
                Task { await engine.delete(doomed) }
            }
        } message: { workflow in
            Text("\(workflow.name) and its execution history go. Nothing in the repository changes.")
        }
    }

    @ViewBuilder private var content: some View {
        if !engine.loaded {
            VStack(spacing: 8) {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if engine.workflows.isEmpty {
            VStack(spacing: 9) {
                Spacer()
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No workflows yet.")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                Text("Automate the Git sequences you run often.")
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
                ActionButton(title: "Create workflow", icon: "plus", prominent: true) {
                    engine.beginCreate()
                }
                .padding(.top, 4)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Automate Git sequences you run often.")
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 2)

                    ForEach(engine.workflows) { workflow in
                        WorkflowRow(workflow: workflow) {
                            pendingDelete = workflow
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            ActionButton(title: "New workflow", icon: "plus", prominent: true) {
                engine.beginCreate()
            }
            .disabled(state.isBusy)
            Spacer(minLength: 0)
            if let problem = engine.problem {
                Text(problem)
                    .font(Theme.micro)
                    .foregroundStyle(Theme.bad)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Row

struct WorkflowRow: View {
    let workflow: GitWorkflow
    let onDelete: () -> Void

    @EnvironmentObject private var state: ProjectSession
    @State private var hovering = false

    private var engine: WorkflowEngine { return state.workflows }

    var body: some View {
        Button {
            Task { await engine.prepare(workflow) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(workflow.name)
                        .font(Theme.bodyEmphasis)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if hovering {
                        actions
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }

                if !workflow.detail.isEmpty {
                    Text(workflow.detail)
                        .font(Theme.micro)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                HStack(spacing: 7) {
                    Text(workflow.flowLabel())
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\u{00b7}")
                        .font(Theme.micro)
                        .foregroundStyle(.tertiary)
                    Text(workflow.stepCountLabel)
                        .font(Theme.micro)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    lastRun
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .fill(hovering ? Theme.surfaceStrong : Theme.surface)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { value in
            withAnimation(Theme.snap) { hovering = value }
        }
        .help("Prepare a run of \(workflow.name)")
    }

    @ViewBuilder private var lastRun: some View {
        if let run = engine.lastRun(of: workflow) {
            HStack(spacing: 4) {
                Image(systemName: run.outcome == .completed ? "checkmark" : "xmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(run.outcome == .completed ? Theme.ok : Theme.bad)
                Text(run.whenLabel)
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
            }
        } else {
            Text("never run")
                .font(Theme.micro)
                .foregroundStyle(.quaternary)
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            QuickAction(icon: "play.fill", help: "Prepare a run") {
                Task { await engine.prepare(workflow) }
            }
            QuickAction(icon: "pencil", help: "Edit") {
                engine.beginEdit(workflow)
            }
            QuickAction(icon: "doc.on.doc", help: "Duplicate") {
                Task { await engine.duplicate(workflow) }
            }
            QuickAction(icon: "trash", help: "Delete", destructive: true) {
                onDelete()
            }
        }
    }
}
