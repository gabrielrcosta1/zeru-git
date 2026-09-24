import SwiftUI

/// What the agent proposed for a failure, and what the app will let it do.
///
/// The agent does not run git. It hands over a list of commands, this panel
/// shows the app's verdict on each one, and anything that could lose work waits
/// for a click on that exact command.
struct PlanPanel: View {
    @EnvironmentObject private var state: ProjectSession

    var body: some View {
        VStack(spacing: 0) {
            if let plan = state.plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // A plan asked for in the chat answers a question. The
                        // last failure may be old and unrelated, and naming it
                        // here would read as the cause of a plan it did not
                        // cause.
                        if let question = state.planQuestion {
                            VStack(alignment: .leading, spacing: 3) {
                                SectionHeader("You asked")
                                Text(question)
                                    .font(Theme.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else if let failure = state.failure {
                            VStack(alignment: .leading, spacing: 3) {
                                SectionHeader("What failed")
                                Text(failure.commandLabel)
                                    .font(Theme.mono)
                                    .foregroundStyle(.secondary)
                                Text(failure.message)
                                    .font(Theme.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if !plan.diagnosis.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                SectionHeader("Diagnosis")
                                Text(plan.diagnosis)
                                    .font(Theme.body)
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if plan.steps.isEmpty {
                            Text("The agent proposed no commands.")
                                .font(Theme.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                SectionHeader(title: "Plan") {
                                    Text(verdictSummary(plan))
                                        .font(Theme.micro)
                                        .foregroundStyle(.tertiary)
                                }
                                ForEach(Array(plan.steps.enumerated()), id: \.element.id) { pair in
                                    PlanStepRow(number: pair.offset + 1, step: pair.element)
                                }
                            }
                        }

                        if let note = plan.note, !note.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                SectionHeader("Afterwards")
                                Text(note)
                                    .font(Theme.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Text("Git Agent classified every command itself. A step that reads or that cannot lose anything runs straight through; a step that can lose work stops and names the command before it runs; a step that is not on the list never runs at all.")
                            .font(Theme.micro)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Hairline()
                footer(plan)
            } else {
                PanelPlaceholder(text: "There is no plan open.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func verdictSummary(_ plan: GitCommandPlan) -> String {
        var parts: [String] = ["\(plan.steps.count) step\(plan.steps.count == 1 ? "" : "s")"]
        let needing = plan.steps.filter { $0.risk.needsConfirmation }.count
        if needing > 0 { parts.append("\(needing) needs you") }
        if plan.refusedCount > 0 { parts.append("\(plan.refusedCount) refused") }
        return parts.joined(separator: " \u{00b7} ")
    }

    private func footer(_ plan: GitCommandPlan) -> some View {
        HStack(spacing: 9) {
            ActionButton(title: plan.isFinished ? "Run again" : "Run the plan",
                         icon: "play.fill",
                         prominent: true,
                         busy: state.runningPlan) {
                Task { await state.runPlan() }
            }
            .disabled(state.runningPlan || state.isBusy || plan.steps.isEmpty)

            // The result is the one thing the agent cannot see. Only offered
            // once something has actually run: before that there is nothing to
            // send back.
            if plan.steps.contains(where: { $0.outcome.isTerminal }) {
                ActionButton(title: plan.failedCount > 0 ? "Send the error back" : "Ask again with the result",
                             icon: "arrow.uturn.left",
                             busy: state.phase == .fixing) {
                    Task { await state.retryPlanWithAI() }
                }
                .disabled(state.runningPlan || state.isBusy || !state.aiAvailable)
                .help(state.aiAvailable
                      ? "Gives the agent this plan and what git answered to every command"
                      : (state.aiProblem ?? "No AI provider is ready"))
            }

            ActionButton(title: "Discard", icon: "xmark") {
                state.discardPlan()
            }
            .disabled(state.runningPlan)

            Spacer(minLength: 0)

            if plan.failedCount > 0 {
                Text("\(plan.failedCount) failed")
                    .font(Theme.micro)
                    .foregroundStyle(Theme.bad)
            } else if plan.isFinished {
                Text("finished")
                    .font(Theme.micro)
                    .foregroundStyle(Theme.ok)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Row

struct PlanStepRow: View {
    let number: Int
    let step: GitCommandStep

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(number)")
                    .font(Theme.numeric)
                    .foregroundStyle(.tertiary)
                    .frame(width: 12, alignment: .trailing)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(step.display)
                        .font(Theme.mono)
                        .foregroundStyle(runnable ? .primary : .tertiary)
                        .strikethrough(!runnable, color: Theme.bad.opacity(0.6))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if !step.why.isEmpty {
                        Text(step.why)
                            .font(Theme.micro)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if case .refused(let why) = step.risk {
                        Text("Refused: \(why).")
                            .font(Theme.micro)
                            .foregroundStyle(Theme.bad)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    outcome
                }

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    Image(systemName: Theme.icon(for: step.risk))
                        .font(.system(size: 8.5))
                    Text(step.risk.label)
                        .font(Theme.micro)
                }
                .foregroundStyle(Theme.color(for: step.risk))
                .padding(.top, 2)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.surface)
        )
    }

    private var runnable: Bool { return step.risk.isRunnable }

    @ViewBuilder private var outcome: some View {
        switch step.outcome {
        case .pending:
            EmptyView()
        case .running:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.5).frame(width: 10, height: 10)
                Text("running")
                    .font(Theme.micro)
                    .foregroundStyle(.secondary)
            }
        case .done(let output):
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.ok)
                    .padding(.top, 2)
                Text(output)
                    .font(Theme.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let problem):
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.bad)
                    .padding(.top, 2)
                Text(problem)
                    .font(Theme.micro)
                    .foregroundStyle(Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .skipped(let why):
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                Text("Skipped: \(why).")
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
