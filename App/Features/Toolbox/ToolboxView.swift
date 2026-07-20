// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

struct ToolboxView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case tools
        case protection
        case history

        var id: Self { self }
        var title: String {
            switch self {
            case .tools: String(localized: "实用工具")
            case .protection: String(localized: "保护规则")
            case .history: String(localized: "操作历史")
            }
        }
    }

    @State private var section = Section.tools

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("工具箱")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("固定范围工具、白名单和所有可追溯操作。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("页面", selection: $section) {
                    ForEach(Section.allCases) { item in Text(item.title).tag(item) }
                }
                .pickerStyle(.segmented)
                .frame(width: 390)
            }
            .padding(28)
            Divider()

            switch section {
            case .tools: ToolboxOverviewView()
            case .protection: ProtectionRulesView()
            case .history: OperationHistoryView()
            }
        }
    }
}
