import SwiftUI

/// Building a workflow. Numbered steps, only the fields each operation needs,
/// and no git command anywhere on screen.
struct WorkflowEditor: View {
    @EnvironmentObject private var state: ProjectSession

    private var engine: WorkflowEngine { return state.workflows }

    var body: some View {
        VStack(spacing: 0) {
            if engine.draft == nil {
                PanelPlaceholder(text: "Nothing is being edited.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        details
                        variables
                        steps
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Hairline()
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Bindings

    private func field<T>(_ keyPath: WritableKeyPath<GitWorkflow, T>, _ fallback: T) -> Binding<T> {
        return Binding(get: { engine.draft?[keyPath: keyPath] ?? fallback },
                       set: { value in engine.draft?[keyPath: keyPath] = value })
    }

    private func step<T>(_ index: Int, _ keyPath: WritableKeyPath<WorkflowStep, T>, _ fallback: T) -> Binding<T> {
        return Binding(
            get: {
                guard let steps = engine.draft?.steps, steps.indices.contains(index) else { return fallback }
                return steps[index][keyPath: keyPath]
            },
            set: { value in
                guard var draft = engine.draft, draft.steps.indices.contains(index) else { return }
                draft.steps[index][keyPath: keyPath] = value
                engine.draft = draft
            })
    }

    private func variable<T>(_ index: Int, _ keyPath: WritableKeyPath<WorkflowVariable, T>, _ fallback: T) -> Binding<T> {
        return Binding(
            get: {
                guard let list = engine.draft?.variables, list.indices.contains(index) else { return fallback }
                return list[index][keyPath: keyPath]
            },
            set: { value in
                guard var draft = engine.draft, draft.variables.indices.contains(index) else { return }
                draft.variables[index][keyPath: keyPath] = value
                engine.draft = draft
            })
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                SectionHeader("Name")
                TextField("Promote Release", text: field(\.name, ""))
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.surface))
            }
            VStack(alignment: .leading, spacing: 3) {
                SectionHeader("Description")
                TextField("Promote a release through environments", text: field(\.detail, ""))
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.surface))
            }
        }
    }

    // MARK: Variables

    private var variables: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Variables") {
                Menu {
                    ForEach(WorkflowVariableKind.allCases) { kind in
                        Button(kind.label) { addVariable(kind) }
                    }
                } label: {
                    Text("+ Add")
                        .font(Theme.micro)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if engine.draft?.variables.isEmpty ?? true {
                Text("Without variables the workflow is nailed to the branch names you type. With them it asks each time it runs.")
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array((engine.draft?.variables ?? []).enumerated()), id: \.element.id) { pair in
                variableRow(pair.offset, pair.element)
            }
        }
    }

    private func variableRow(_ index: Int, _ value: WorkflowVariable) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                TextField("NAME", text: variable(index, \.name, ""))
                    .textFieldStyle(.plain)
                    .font(Theme.mono)
                    .frame(width: 130)

                Picker("", selection: variable(index, \.kind, .branch)) {
                    ForEach(WorkflowVariableKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()

                Spacer(minLength: 0)

                Text("{{\(value.name)}}")
                    .font(Theme.micro)
                    .foregroundStyle(.quaternary)
                    .textSelection(.enabled)

                QuickAction(icon: "trash", help: "Remove", destructive: true) {
                    guard var draft = engine.draft else { return }
                    draft.variables.remove(at: index)
                    engine.draft = draft
                }
            }

            if value.kind.isList {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(value.values.enumerated()), id: \.offset) { item in
                        HStack(spacing: 6) {
                            Text("\u{2022}")
                                .font(Theme.micro)
                                .foregroundStyle(.tertiary)
                            NameField(text: Binding(
                                get: {
                                    guard let list = engine.draft?.variables, list.indices.contains(index),
                                          list[index].values.indices.contains(item.offset) else { return "" }
                                    return list[index].values[item.offset]
                                },
                                set: { newValue in
                                    guard var draft = engine.draft, draft.variables.indices.contains(index),
                                          draft.variables[index].values.indices.contains(item.offset) else { return }
                                    draft.variables[index].values[item.offset] = newValue
                                    engine.draft = draft
                                }),
                                placeholder: "branch",
                                suggestions: branchNames,
                                tokens: [])
                            QuickAction(icon: "minus", help: "Remove") {
                                guard var draft = engine.draft, draft.variables.indices.contains(index) else { return }
                                draft.variables[index].values.remove(at: item.offset)
                                engine.draft = draft
                            }
                        }
                    }
                    Button("+ Add branch") {
                        guard var draft = engine.draft, draft.variables.indices.contains(index) else { return }
                        draft.variables[index].values.append("")
                        engine.draft = draft
                    }
                    .buttonStyle(.link)
                    .font(Theme.micro)
                }
                .padding(.leading, 4)
            } else {
                NameField(text: variable(index, \.value, ""),
                          placeholder: value.kind == .remote ? "origin" : "value",
                          suggestions: value.kind == .branch ? branchNames : (value.kind == .remote ? ["origin"] : []),
                          tokens: [])
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
    }

    private func addVariable(_ kind: WorkflowVariableKind) {
        guard var draft = engine.draft else { return }
        let base = kind == .remote ? "REMOTE" : (kind.isList ? "TARGETS" : "SOURCE")
        var name = base
        var counter = 2
        while draft.variables.contains(where: { $0.name == name }) {
            name = base + "\(counter)"
            counter += 1
        }
        var value = WorkflowVariable(name: name, kind: kind)
        if kind == .remote { value.value = "origin" }
        if kind.isList { value.values = [""] }
        draft.variables.append(value)
        engine.draft = draft
    }

    // MARK: Steps

    private var steps: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Steps") {
                Text(engine.draft?.stepCountLabel ?? "")
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
            }

            ForEach(Array((engine.draft?.steps ?? []).enumerated()), id: \.element.id) { pair in
                stepRow(pair.offset, pair.element)
            }

            HStack {
                Spacer(minLength: 0)
                Menu {
                    ForEach(WorkflowStepKind.allCases) { kind in
                        Button {
                            addStep(kind)
                        } label: {
                            Label(kind.label, systemImage: kind.icon)
                        }
                    }
                } label: {
                    Text("+ Add step")
                        .font(Theme.caption)
                        .foregroundStyle(Color.accentColor)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.top, 2)
        }
    }

    private func stepRow(_ index: Int, _ value: WorkflowStep) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(String(format: "%02d", index + 1))
                    .font(Theme.numeric)
                    .foregroundStyle(.tertiary)

                Picker("", selection: step(index, \.kind, .checkout)) {
                    ForEach(WorkflowStepKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()

                Spacer(minLength: 0)

                QuickAction(icon: "chevron.up", help: "Move earlier") { move(index, by: -1) }
                    .disabled(index == 0)
                QuickAction(icon: "chevron.down", help: "Move later") { move(index, by: 1) }
                    .disabled(index >= (engine.draft?.steps.count ?? 1) - 1)
                QuickAction(icon: "doc.on.doc", help: "Duplicate") { duplicate(index) }
                QuickAction(icon: "trash", help: "Remove", destructive: true) { remove(index) }
            }

            if value.kind.usesBranch {
                labelled(value.kind.branchLabel) {
                    NameField(text: step(index, \.branch, ""),
                              placeholder: "branch",
                              suggestions: branchNames,
                              tokens: tokenNames)
                }
            }
            if value.kind.usesRemote {
                labelled("Remote") {
                    NameField(text: step(index, \.remote, ""),
                              placeholder: "origin",
                              suggestions: ["origin"],
                              tokens: tokenNames)
                }
            }
            if value.kind.usesText {
                labelled(value.kind.textLabel) {
                    TextField("", text: step(index, \.text, ""))
                        .textFieldStyle(.plain)
                        .font(Theme.body)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.surfaceStrong))
                }
            }
            if value.kind.usesRebaseToggle {
                Toggle(isOn: step(index, \.rebase, false)) {
                    Text("Rebase instead of merging")
                        .font(Theme.micro)
                }
                .toggleStyle(.checkbox)
            }

            if !listNames.isEmpty {
                HStack(spacing: 6) {
                    Text("Repeat for")
                        .font(Theme.micro)
                        .foregroundStyle(.tertiary)
                    Picker("", selection: step(index, \.repeatFor, "")) {
                        Text("no repeat").tag("")
                        ForEach(listNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    if value.repeats {
                        Text("uses {{EACH}}")
                            .font(Theme.micro)
                            .foregroundStyle(.quaternary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
    }

    private func labelled<Content: View>(_ title: String, @ViewBuilder _ inner: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.micro)
                .foregroundStyle(.tertiary)
            inner()
        }
    }

    // MARK: Step actions

    private func addStep(_ kind: WorkflowStepKind) {
        guard var draft = engine.draft else { return }
        var value = WorkflowStep(kind: kind)
        if kind.usesRemote {
            value.remote = draft.variables.first { $0.kind == .remote }.map { "{{\($0.name)}}" } ?? "origin"
        }
        // A new step joins whatever the one above it repeats for: that is what
        // the user meant nine times out of ten.
        if let last = draft.steps.last { value.repeatFor = last.repeatFor }
        draft.steps.append(value)
        engine.draft = draft
    }

    private func move(_ index: Int, by offset: Int) {
        guard var draft = engine.draft else { return }
        let target = index + offset
        guard draft.steps.indices.contains(index), draft.steps.indices.contains(target) else { return }
        draft.steps.swapAt(index, target)
        engine.draft = draft
    }

    private func duplicate(_ index: Int) {
        guard var draft = engine.draft, draft.steps.indices.contains(index) else { return }
        var copy = draft.steps[index]
        copy.id = UUID()
        draft.steps.insert(copy, at: index + 1)
        engine.draft = draft
    }

    private func remove(_ index: Int) {
        guard var draft = engine.draft, draft.steps.indices.contains(index) else { return }
        draft.steps.remove(at: index)
        engine.draft = draft
    }

    // MARK: Suggestions

    private var branchNames: [String] {
        var names: [String] = []
        for branch in state.branches {
            let name = branch.isRemote ? branch.localName : branch.name
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    private var tokenNames: [String] {
        var tokens = (engine.draft?.variables ?? []).map { "{{\($0.name)}}" }
        if !(engine.draft?.variables.contains { $0.kind.isList } ?? false) { return tokens }
        tokens.append("{{EACH}}")
        return tokens
    }

    private var listNames: [String] {
        return (engine.draft?.variables ?? []).filter { $0.kind.isList }.map { $0.name }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 9) {
            ActionButton(title: "Save workflow", icon: "checkmark", prominent: true) {
                Task { await engine.saveDraft() }
            }
            .disabled(engine.draftProblem != nil)
            ActionButton(title: "Cancel", icon: "xmark") {
                engine.cancelEdit()
            }
            Spacer(minLength: 0)
            if let problem = engine.draftProblem {
                Text(problem)
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

// MARK: - A name with suggestions

/// A field that takes a branch name, with the branches of this repository and
/// the workflow's own variables one click away.
struct NameField: View {
    @Binding var text: String
    let placeholder: String
    let suggestions: [String]
    let tokens: [String]

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.body)

            if !suggestions.isEmpty || !tokens.isEmpty {
                Menu {
                    if !tokens.isEmpty {
                        Section("Variables") {
                            ForEach(tokens, id: \.self) { token in
                                Button(token) { text = token }
                            }
                        }
                    }
                    if !suggestions.isEmpty {
                        Section("Branches") {
                            ForEach(suggestions.prefix(40), id: \.self) { name in
                                Button(name) { text = name }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.surfaceStrong))
    }
}
