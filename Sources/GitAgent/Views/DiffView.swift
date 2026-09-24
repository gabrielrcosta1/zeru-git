import SwiftUI

struct DiffView: View {
    let diff: FileDiff?
    let loading: Bool

    private let gutter: CGFloat = 30
    private let charWidth: CGFloat = 6.65

    var body: some View {
        Group {
            if loading {
                center { ProgressView().controlSize(.small) }
            } else if let diff, diff.isBinary {
                center {
                    VStack(spacing: 4) {
                        Image(systemName: "doc.badge.gearshape")
                            .font(.system(size: 18, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("Binary file")
                            .font(Theme.uiSmall)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let diff, !diff.hunks.isEmpty {
                content(diff)
            } else {
                center {
                    Text("No diff to show")
                        .font(Theme.uiSmall)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func center<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ diff: FileDiff) -> some View {
        return DiffBody(diff: diff)
    }
}

/// The scrollable body of a diff, shared by the panel and the inline expansion.
struct DiffBody: View {
    let diff: FileDiff

    private let gutter: CGFloat = 30
    private let charWidth: CGFloat = 6.65

    var body: some View {
        let width = rowWidth(diff)
        return ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(diff.hunks) { hunk in
                    HunkHeaderRow(header: hunk.header, width: width, gutter: gutter)
                    ForEach(hunk.lines) { line in
                        DiffLineRow(line: line, width: width, gutter: gutter)
                    }
                }
                if diff.truncated {
                    Text("  diff truncated at \(DiffParser.lineLimit) lines")
                        .font(Theme.codeNumber)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 6)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Monospaced rows need an explicit width so the row backgrounds line up
    /// while the view scrolls horizontally.
    private func rowWidth(_ diff: FileDiff) -> CGFloat {
        var longest = 40
        for hunk in diff.hunks {
            for line in hunk.lines where line.text.count > longest {
                longest = line.text.count
            }
        }
        longest = min(longest, 400)
        return gutter * 2 + 16 + CGFloat(longest) * charWidth + 24
    }
}

struct HunkHeaderRow: View {
    let header: String
    let width: CGFloat
    let gutter: CGFloat

    var body: some View {
        Text(header)
            .font(Theme.codeNumber)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, 8)
            .padding(.vertical, 3)
            .frame(width: width, alignment: .leading)
            .background(Color.primary.opacity(0.05))
    }
}

struct DiffLineRow: View {
    let line: DiffLine
    let width: CGFloat
    let gutter: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Text(line.oldNumber.map { String($0) } ?? "")
                .font(Theme.codeNumber)
                .foregroundStyle(.tertiary)
                .frame(width: gutter, alignment: .trailing)
            Text(line.newNumber.map { String($0) } ?? "")
                .font(Theme.codeNumber)
                .foregroundStyle(.tertiary)
                .frame(width: gutter, alignment: .trailing)
            Text(marker)
                .font(Theme.code)
                .foregroundStyle(foreground)
                .frame(width: 16, alignment: .center)
            Text(line.text.isEmpty ? " " : line.text)
                .font(Theme.code)
                .foregroundStyle(line.kind == .noNewline ? Color.secondary : Color.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .frame(width: width, alignment: .leading)
        .background(background)
    }

    private var marker: String {
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "\u{2212}"
        case .noNewline: return "\u{29f8}"
        case .context: return ""
        }
    }

    private var foreground: Color {
        switch line.kind {
        case .addition: return Theme.added
        case .deletion: return Theme.removed
        default: return .secondary
        }
    }

    private var background: Color {
        switch line.kind {
        case .addition: return Theme.addedBackground
        case .deletion: return Theme.removedBackground
        default: return .clear
        }
    }
}
