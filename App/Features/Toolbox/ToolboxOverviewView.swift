// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

struct ToolboxOverviewView: View {
    @State private var selectedTool: ToolboxEngineTool?
    @State private var showsSystemMaintenance = false

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 18)], spacing: 18) {
                ToolActionCard(
                    title: String(localized: "开发缓存"),
                    detail: String(localized: "DerivedData、SwiftPM、npm、Go 与 pip 缓存"),
                    symbol: "hammer",
                    color: SpruceTheme.accent,
                    actionTitle: String(localized: "扫描")
                ) { selectedTool = .developer }

                ToolActionCard(
                    title: String(localized: "安装包"),
                    detail: String(localized: "扫描下载目录中的 DMG、PKG、MPKG 与 ISO"),
                    symbol: "shippingbox",
                    color: .orange,
                    actionTitle: String(localized: "扫描")
                ) { selectedTool = .installers }

                ToolActionCard(
                    title: String(localized: "系统维护"),
                    detail: String(localized: "显示并复制固定的 DNS 与 Spotlight 维护命令"),
                    symbol: "wrench.and.screwdriver",
                    color: .blue,
                    actionTitle: String(localized: "查看命令")
                ) { showsSystemMaintenance = true }
            }
            .padding(28)
        }
        .sheet(item: $selectedTool) { tool in
            ToolPlanView(tool: tool)
        }
        .sheet(isPresented: $showsSystemMaintenance) {
            SystemMaintenanceView()
        }
    }
}

private struct ToolActionCard: View {
    let title: String
    let detail: String
    let symbol: String
    let color: Color
    let actionTitle: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(color)
                    .frame(width: 46, height: 46)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                Spacer()
                if !isEnabled { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title3.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
                .disabled(!isEnabled)
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .cardSurface()
    }
}

extension ToolboxEngineTool: Identifiable {
    var id: Self { self }
}
