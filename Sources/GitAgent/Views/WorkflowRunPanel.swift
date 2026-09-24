import SwiftUI

/// Getting a workflow ready, watching it run, and looking at what it did.
struct WorkflowRunPanel: View {
    @EnvironmentObject private var state: ProjectSession

    private var engine: WorkflowEngine { return state.workflows }

    var body: some View {
        VStack(spacing: 0) {
            if let run = engine.visibleRun {
                RunView(run: run)
            } else if engine.prepared != nil {
                PrepareView()
            } else {
                PanelPlaceholder(text: "No workflow is ready to run.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Before it starts

struct PrepareView: View {
    @EnvironmentObject private var state: ProjectSession

    private var engine: WorkflowEngine { return state.workflows }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let prepared = engine.prepared {
                        flow(prepared)
                        if !prepared.workflow.variables.isEmpty { values(prepared) }
                        checks(prepared)
                        review(prepared)
                        context
                        history(prepared)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Hairline()
            footer
        }
    }

    private func flow(_ prepared: PreparedRun) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(prepared.workflow.flowLabel(values: prepared.values))
                .font(Theme.projectTitle)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !prepared.workflow.detail.isEmpty {
                Text(prepared.workflow.detail)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Values

    private func values(_ prepared: PreparedRun) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeader("This run")
            ForEach(prepared.workflow.variables) { variable in
                if variable.kind.isList {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(variable.name)
                            .font(Theme.micro)
                            .foregroundStyle(.tertiary)
                        HStack(spacing: 8) {
                            ForEach(variable.values, id: \.self) { value in
                                let chosen = (prepared.values.selected[variable.name] ?? []).contains(value)
                                Button {
                                    engine.toggleTarget(value, in: variable.name)
                                } label: {
                                    HStack(spacing: 5) {
                                        Checkbox(state: chosen ? .on : .off)
                                        Text(value)
                                            .font(Theme.body)
                                            .foregroundStyle(chosen ? .primary : .secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(variable.name)
                            .font(Theme.micro)
                            .foregroundStyle(.tertiary)
                        NameField(text: Binding(
                            get: { engine.prepared?.values.single[variable.name] ?? "" },
                            set: { engine.setValue($0, for: variable.name) }),
                            placeholder: variable.kind == .remote ? "origin" : "branch",
                            suggestions: variable.kind == .remote ? ["origin"] : branchNames,
                            tokens: [])
                    }
                }
            }
        }
    }

    private var branchNames: [String] {
        var names: [String] = []
        for branch in state.branches {
            let name = branch.isRemote ? branch.localName : branch.name
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    // MARK: Checks

    private func checks(_ prepared: PreparedRun) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader("Before it starts")
            if let problem = prepared.problem {
                banner(problem, detail: nil)
            }
            ForEach(prepared.checks) { check in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: check.passed ? "checkmark" : "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(check.passed ? Theme.ok : Theme.bad)
                        .frame(width: 12)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(check.title)
                            .font(Theme.caption)
                            .foregroundStyle(check.passed ? .secondary : .primary)
                        if let detail = check.detail {
                            Text(detail)
                                .font(Theme.micro)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            if state.repo?.hasChanges == true {
                ActionButton(title: "View changes", icon: "plus.forwardslash.minus") {
                    Task { await state.openAllChanges() }
                }
                .padding(.top, 2)
            }
        }
    }

    private func banner(_ text: String, detail: String?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(Theme.bad)
                .padding(.top, 1)
            Text(text)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: Review

    private func review(_ prepared: PreparedRun) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader(title: "What it will do") {
                Text("\(prepared.steps.count) step\(prepared.steps.count == 1 ? "" : "s")")
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(prepared.steps.enumerated()), id: \.element.id) { pair in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(format: "%02d", pair.offset + 1))
                        .font(Theme.numeric)
                        .foregroundStyle(.quaternary)
                    Image(systemName: pair.element.kind.icon)
                        .font(.system(size: 8.5))
                        .foregroundStyle(pair.element.kind.isWeighty ? Theme.warn : Color.secondary)
                        .frame(width: 12)
                    Text(pair.element.title)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var context: some View {
        HStack(spacing: 14) {
            labelled("Current branch", state.repo?.branchLabel ?? "\u{2014}")
            labelled("Working tree", state.repo?.hasChanges == true
                     ? "\(state.repo?.changes.count ?? 0) changes"
                     : "clean")
            Spacer(minLength: 0)
        }
    }

    private func labelled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(Theme.sectionLabel)
                .kerning(0.8)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: History

    @ViewBuilder private func history(_ prepared: PreparedRun) -> some View {
        let past = engine.runs(of: prepared.workflow)
        if !past.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                SectionHeader("Execution history")
                ForEach(past.prefix(8)) { run in
                    Button {
                        engine.open(run: run)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: run.outcome == .completed ? "checkmark" : "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(run.outcome == .completed ? Theme.ok : Theme.bad)
                                .frame(width: 12)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(run.whenLabel)
                                    .font(Theme.caption)
                                    .foregroundStyle(.secondary)
                                Text(run.flowLabel)
                                    .font(Theme.micro)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text(run.outcome == .completed
                                 ? "in " + run.durationLabel
                                 : (run.problem ?? run.outcome.label))
                                .font(Theme.micro)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 9) {
            ActionButton(title: "Execute workflow",
                         icon: "play.fill",
                         prominent: true,
                         busy: engine.running) {
                engine.start()
            }
            .disabled(!engine.canExecute || state.isBusy)

            ActionButton(title: "Cancel", icon: "xmark") {
                engine.prepared = nil
                state.openWorkflows()
            }

            Spacer(minLength: 0)

            if let prepared = engine.prepared, !prepared.canRun {
                Text(prepared.problem ?? "Fix what is listed above first.")
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - While it runs, and afterwards

struct RunView: View {
    let run: WorkflowRun
    @EnvironmentObject private var state: ProjectSession

    private var engine: WorkflowEngine { return state.workflows }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(run.steps.enumerated()), id: \.element.id) { pair in
                            RunStepRow(number: pair.offset + 1, step: pair.element)
                        }
                    }
                    if let problem = run.problem, run.outcome != .completed {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.bad)
                                    .padding(.top, 1)
                                Text(problem)
                                    .font(Theme.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            Text("Everything above it already ran. Nothing after it did.")
                                .font(Theme.micro)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                                .fill(Theme.bad.opacity(0.09))
                        )
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Hairline()
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(run.flowLabel)
                .font(Theme.projectTitle)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 7) {
                Pill(text: run.outcome.label.lowercased(),
                     color: run.outcome == .completed ? Theme.ok
                        : (run.outcome == .running ? .secondary : Theme.bad))
                Text("\(run.doneCount) of \(run.steps.count)")
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
                if run.finishedAt != nil {
                    Text("\u{00b7} " + run.durationLabel)
                        .font(Theme.micro)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Text(run.whenLabel)
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            if engine.running {
                ActionButton(title: "Abort", icon: "stop.fill") {
                    engine.abort()
                }
                .help("Stops before the next step. A command already running is left to finish.")
            } else {
                if state.repo?.hasConflicts == true {
                    ActionButton(title: "Resolve conflicts", icon: "exclamationmark.triangle.fill", prominent: true) {
                        Task { await state.openAllChanges() }
                    }
                }
                ActionButton(title: "Back to workflows", icon: "chevron.left") {
                    engine.closeRun()
                    state.openWorkflows()
                }
            }
            Spacer(minLength: 0)
            if engine.running {
                Text("Running \u{2014} the repository is being changed.")
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - One step of a run

struct RunStepRow: View {
    let number: Int
    let step: WorkflowRunStep

    @EnvironmentObject private var state: ProjectSession
    @State private var hovering = false

    private var engine: WorkflowEngine { return state.workflows }
    private var isOpen: Bool { return engine.openStep == step.id }
    private var hasOutput: Bool { return !step.output.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard hasOutput else { return }
                withAnimation(Theme.ease) {
                    engine.openStep = isOpen ? nil : step.id
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    marker
                        .frame(width: 14)
                    Text("\(number)")
                        .font(Theme.numeric)
                        .foregroundStyle(.quaternary)
                    Text(step.title)
                        .font(Theme.body)
                        .foregroundStyle(step.state == .pending || step.state == .skipped ? .tertiary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    if step.state == .done || step.state == .failed {
                        Text(step.durationLabel)
                            .font(Theme.micro)
                            .foregroundStyle(.quaternary)
                    }
                    if hasOutput {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOpen ? Theme.surfaceStrong : (hovering ? Theme.surface : .clear))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { value in
                withAnimation(Theme.snap) { hovering = value }
            }

            if isOpen {
                VStack(alignment: .leading, spacing: 5) {
                    Text(step.command)
                        .font(Theme.mono)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                    Text(step.output)
                        .font(Theme.code)
                        .foregroundStyle(step.state == .failed ? Theme.bad : Color.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if step.duration > 0 {
                        Text("Took " + step.durationLabel)
                            .font(Theme.micro)
                            .foregroundStyle(.quaternary)
                    }
                }
                .padding(.horizontal, 31)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var marker: some View {
        if step.state == .running {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)
        } else {
            Image(systemName: Theme.icon(for: step.state))
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Theme.color(for: step.state))
        }
    }
}
