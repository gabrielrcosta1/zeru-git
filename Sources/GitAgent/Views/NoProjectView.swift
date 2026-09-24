import SwiftUI

/// Shown when no project is open at all.
struct NoProjectView: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        VStack(spacing: 14) {
            Spacer()

            BrandMark(size: 52)

            VStack(spacing: 3) {
                Text("Git Agent")
                    .font(Theme.title)
                Text("Open a folder that contains a git repository. You can keep several open at once.")
                    .font(Theme.uiSmall)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280)
            }

            ActionButton(title: "Open Project", icon: "folder", prominent: true) {
                workspace.chooseProject()
            }
            .padding(.top, 2)

            if !workspace.recentProjects.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("RECENT")
                        .font(Theme.sectionLabel)
                        .kerning(0.8)
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 2)
                    ForEach(workspace.recentProjects.prefix(5), id: \.self) { path in
                        Button {
                            Task { await workspace.open(url: URL(fileURLWithPath: path, isDirectory: true)) }
                        } label: {
                            HStack(spacing: 6) {
                                ProjectDot(name: (path as NSString).lastPathComponent)
                                Text((path as NSString).lastPathComponent)
                                    .font(Theme.caption)
                                Text((path as NSString).deletingLastPathComponent)
                                    .font(Theme.micro)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(.top, 8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}
