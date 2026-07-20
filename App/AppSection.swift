// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard
    case cleanup
    case applications
    case analyzer
    case toolbox

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .dashboard: "概览"
        case .cleanup: "智能清理"
        case .applications: "应用卸载"
        case .analyzer: "空间分析"
        case .toolbox: "工具箱"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "sparkles"
        case .cleanup: "leaf"
        case .applications: "square.grid.2x2"
        case .analyzer: "chart.pie"
        case .toolbox: "wrench.and.screwdriver"
        }
    }
}
