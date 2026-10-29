import SwiftUI

struct WorkshopUpdatesMenu: View {
    @EnvironmentObject private var workshop: WorkshopViewModel

    var body: some View {
        Menu {
            Button("检查工坊更新") { workshop.checkForUpdates(force: true) }
                .disabled(workshop.isCheckingUpdates)
            Button("更新 / 校验全部（\(workshop.pendingUpdateCount)）") { workshop.updateAllWallpapers() }
                .disabled(workshop.pendingUpdateCount == 0)
            if let last = workshop.lastUpdateCheckAt {
                Text("上次检查 \(last.formatted(date: .omitted, time: .shortened))")
            }
        } label: {
            Image(systemName: workshop.pendingUpdateCount > 0 ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(workshop.pendingUpdateCount > 0 ? Color.accentColor : Color.primary.opacity(0.85))
                .rotatingWhileVisible(workshop.isCheckingUpdates)
                .frame(width: 34, height: 34)
                .sceneGlass(in: Circle(), interactive: true)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(workshop.isCheckingUpdates ? "正在检查工坊更新" : "工坊更新（\(workshop.pendingUpdateCount) 个待更新或校验）")
        .accessibilityLabel("工坊内容更新")
    }
}
