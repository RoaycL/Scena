import SwiftUI

struct WorkshopUpdatesMenu: View {
    @EnvironmentObject private var workshop: WorkshopViewModel

    var body: some View {
        Menu {
            Button("检查工坊更新") { workshop.checkForUpdates(force: true) }
                .disabled(workshop.isCheckingUpdates)
            Button("更新全部（\(workshop.pendingUpdateCount)）") { workshop.updateAllWallpapers() }
                .disabled(workshop.pendingUpdateCount == 0)
            if workshop.pendingValidationCount > 0 {
                Divider()
                Button("校验旧记录（\(workshop.pendingValidationCount)）") { workshop.validateOldWallpapers() }
            }
            if let last = workshop.lastUpdateCheckAt {
                Text("上次检查 \(last.formatted(date: .omitted, time: .shortened))")
            }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(workshop.pendingUpdateCount > 0 ? Color.accentColor : Color.primary.opacity(0.85))
                .rotatingWhileVisible(workshop.isCheckingUpdates)
                .frame(width: 34, height: 34)
                .sceneGlass(in: Circle(), interactive: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 34, height: 34)
        .help(workshop.isCheckingUpdates ? "正在检查工坊更新" : "工坊更新：\(workshop.pendingUpdateCount) 个可更新，\(workshop.pendingValidationCount) 个旧记录待校验")
        .accessibilityLabel("工坊内容更新")
    }
}
