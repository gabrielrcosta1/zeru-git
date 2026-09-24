import SwiftUI

/// Two views of one panel. The timeline is what happened to the repository,
/// kept on disk so it survives a restart. The log is the running commentary of
/// what the app and the agent did to get there, and lives only in memory.
struct ActivityView: View {
    @EnvironmentObject private var state: ProjectSession

    var body: some View {
        VStack(spacing: 0) {
            ActivityModePicker()
            Hairline()
            switch state.activityMode {
            case .timeline:
                TimelineList()
            case .log:
                ActivityLog()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Mode

struct ActivityModePicker: View {
    @EnvironmentObject private var state: ProjectSession

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ActivityMode.allCases, id: \.self) { mode in
                Button {
                    state.activityMode = mode
                } label: {
                    Text(mode.label)
                        .font(Theme.caption)
                        .foregroundStyle(state.activityMode == mode ? .primary : .secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(state.activityMode == mode ? Theme.surfaceStrong : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 6)
            Text(count)
                .font(Theme.micro)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var count: String {
        switch state.activityMode {
        case .timeline:
            let total = state.timeline.count
            return total == 1 ? "1 operation" : "\(total) operations"
        case .log:
            let total = state.agentActivity.count
            return total == 1 ? "1 line" : "\(total) lines"
        }
    }
}

// MARK: - Timeline

/// Newest first, grouped by day.
struct TimelineList: View {
    @EnvironmentObject private var state: ProjectSession

    var body: some View {
        // Grouped once per redraw, never inside the row builder.
        let groups = days
        let firstKey = groups.first?.key
        return Group {
            if groups.isEmpty {
                PanelPlaceholder(text: "Nothing has happened in this project yet.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { day in
                            Text(day.title.uppercased())
                                .font(Theme.sectionLabel)
                                .kerning(0.8)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 14)
                                .padding(.top, day.key == firstKey ? 12 : 18)
                                .padding(.bottom, 6)

                            ForEach(day.records) { record in
                                TimelineRow(record: record)
                            }
                        }
                    }
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private struct Day: Identifiable {
        let key: String
        let title: String
        var records: [OperationRecord]
        var id: String { return key }
    }

    /// The log is stored oldest first; the timeline reads the other way round.
    private var days: [Day] {
        var result: [Day] = []
        for record in state.timeline.reversed() {
            if let last = result.last, last.key == record.dayKey {
                result[result.count - 1].records.append(record)
            } else {
                result.append(Day(key: record.dayKey, title: record.dayTitle, records: [record]))
            }
        }
        return result
    }
}

struct TimelineRow: View {
    let record: OperationRecord
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text(record.time)
                .font(Theme.numeric)
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .leading)
                .padding(.top, 1)

            Image(systemName: Theme.icon(for: record.operation))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(record.ok ? Theme.color(for: record.operation) : Theme.bad)
                .frame(width: 14)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.operation.label)
                        .font(Theme.bodyEmphasis)
                        .foregroundStyle(.primary)
                    if !record.ok {
                        Text("failed")
                            .font(Theme.micro)
                            .foregroundStyle(Theme.bad)
                    }
                    if let sha = record.shortHeadBefore {
                        Spacer(minLength: 4)
                        Text(sha)
                            .font(Theme.mono)
                            .foregroundStyle(.quaternary)
                            .opacity(hovering ? 1 : 0)
                            .help("HEAD was on \(sha) before this")
                    }
                }
                if !record.subject.isEmpty {
                    Text(record.subject)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail = record.detail, !detail.isEmpty {
                    Text(detail)
                        .font(Theme.micro)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Theme.surface : Color.clear)
        .onHover { value in
            withAnimation(Theme.snap) { hovering = value }
        }
    }
}

// MARK: - Log

struct ActivityLog: View {
    @EnvironmentObject private var state: ProjectSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if state.agentActivity.isEmpty {
                        Text("Nothing has happened yet.")
                            .font(Theme.uiSmall)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }
                    ForEach(state.agentActivity) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text(line.time)
                                .font(Theme.codeNumber)
                                .foregroundStyle(.tertiary)
                                .frame(width: 32, alignment: .leading)
                            Image(systemName: Theme.icon(for: line.kind))
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.color(for: line.kind))
                                .frame(width: 12)
                                .padding(.top, 2)
                            Text(line.text)
                                .font(Theme.uiSmall)
                                .foregroundStyle(line.kind == .info ? .secondary : .primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .id(line.id)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: state.agentActivity.last?.id) { _ in
                if let last = state.agentActivity.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            // The log is only mounted while it is the one on screen, so it has
            // to jump to the newest line itself instead of relying on onChange.
            .onAppear {
                guard let last = state.agentActivity.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}
