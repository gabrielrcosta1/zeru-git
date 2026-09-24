import SwiftUI

struct ReviewView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let review = state.review {
                    resultBody(review)
                } else if state.phase == .reviewing {
                    placeholder(icon: "sparkles", title: "Reviewing changes\u{2026}",
                                subtitle: "The Cursor agent is reading the diff and the files it touches.")
                } else if state.repo?.hasChanges == true {
                    placeholder(icon: "sparkles", title: "No review yet",
                                subtitle: "Run Review Changes (\u{2318}\u{21e7}R) to have the agent inspect the current diff.")
                } else {
                    placeholder(icon: "checkmark.circle", title: "Nothing to review",
                                subtitle: "The working tree is clean.")
                }

                if !state.touchedFiles.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI changed \(state.touchedFiles.count) file\(state.touchedFiles.count == 1 ? "" : "s")")
                            .font(Theme.uiBold)
                        ForEach(state.touchedFiles, id: \.self) { file in
                            HStack(spacing: 5) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.accentColor)
                                Text(file)
                                    .font(Theme.uiSmall)
                                    .textSelection(.enabled)
                            }
                        }
                        if let report = state.lastAgentReport, !report.isEmpty {
                            Text(report)
                                .font(Theme.uiSmall)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func resultBody(_ review: ReviewResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !review.parsed {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AGENT OUTPUT")
                        .font(Theme.uiTiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(.tertiary)
                    Text(review.rawText)
                        .font(Theme.code)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 6) {
                    Text("SUMMARY")
                        .font(Theme.uiTiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Pill(text: "risk \(review.risk.label.lowercased())",
                         color: Theme.color(for: review.risk),
                         filled: review.risk == .high)
                }
                Text(review.summary.isEmpty ? "No summary returned." : review.summary)
                    .font(Theme.ui)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if !review.problems.isEmpty {
                    Divider()
                    Text("PROBLEMS")
                        .font(Theme.uiTiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(.tertiary)
                    ForEach(review.problems) { problem in
                        ProblemCard(problem: problem) {
                            Task { await state.fix(problem: problem) }
                        }
                    }
                }

                if !review.suggestions.isEmpty {
                    Divider()
                    Text("SUGGESTIONS")
                        .font(Theme.uiTiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(.tertiary)
                    ForEach(Array(review.suggestions.enumerated()), id: \.offset) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Text("\u{2022}")
                                .font(Theme.uiSmall)
                                .foregroundStyle(.tertiary)
                            Text(item.element)
                                .font(Theme.uiSmall)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func placeholder(icon: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(Theme.uiBold)
            }
            Text(subtitle)
                .font(Theme.uiSmall)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ProblemCard: View {
    let problem: AIProblem
    let onFix: () -> Void

    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Pill(text: problem.severity.label.lowercased(), color: Theme.color(for: problem.severity))
                Text(problem.title)
                    .font(Theme.uiBold)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
            }
            if let location = problem.location {
                Text(location)
                    .font(Theme.codeNumber)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !problem.detail.isEmpty {
                Text(problem.detail)
                    .font(Theme.uiSmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button {
                    onFix()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "wand.and.stars").font(.system(size: 9))
                        Text("Fix with AI").font(Theme.uiTiny)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(state.isBusy || !state.cliAvailable)

                if let file = problem.file,
                   let change = state.repo?.changes.first(where: { $0.path == file }) {
                    Button("Show diff") {
                        Task { await state.select(change: change) }
                    }
                    .buttonStyle(.link)
                    .font(Theme.uiTiny)
                }
            }
            .padding(.top, 1)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}
