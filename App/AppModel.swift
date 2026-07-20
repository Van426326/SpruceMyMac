// SPDX-License-Identifier: GPL-3.0-only

import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedSection: AppSection? = .dashboard
    @Published var systemSnapshot = SystemSnapshot.empty
    @Published var isRefreshingSystemSnapshot = false

    private let systemMonitor = SystemMonitor()

    func refreshSystemSnapshot() async {
        guard !isRefreshingSystemSnapshot else { return }
        isRefreshingSystemSnapshot = true
        systemSnapshot = await systemMonitor.snapshot()
        isRefreshingSystemSnapshot = false
    }
}
