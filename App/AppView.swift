// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

struct AppView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $model.selectedSection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.vertical, 7)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 218, max: 250)
            .safeAreaInset(edge: .top) {
                brand
            }
            .safeAreaInset(edge: .bottom) {
                engineStatus
            }
        } detail: {
            Group {
                switch model.selectedSection ?? .dashboard {
                case .dashboard:
                    DashboardView(model: model)
                case .cleanup:
                    CleanupView()
                case .applications:
                    ApplicationsView()
                case .analyzer:
                    SpaceAnalyzerView()
                case .toolbox:
                    ToolboxView()
                }
            }
            .background(SpruceTheme.canvas)
        }
        .tint(SpruceTheme.accent)
    }

    private var brand: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(SpruceTheme.accent.gradient)
                Image(systemName: "tree.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 1) {
                Text("SpruceMyMac")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text("让 Mac 轻盈如新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var engineStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(SpruceTheme.accent)
                .frame(width: 7, height: 7)
            Text("安全执行模式")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
    }
}
