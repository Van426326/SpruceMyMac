// SPDX-License-Identifier: GPL-3.0-only

import Foundation

struct SystemSnapshot: Sendable, Equatable {
    let storageTotal: Int64
    let storageAvailable: Int64
    let memoryTotal: Int64
    let memoryUsed: Int64
    let capturedAt: Date

    var storageUsed: Int64 { max(0, storageTotal - storageAvailable) }
    var storageUsageFraction: Double { fraction(storageUsed, of: storageTotal) }
    var memoryUsageFraction: Double { fraction(memoryUsed, of: memoryTotal) }

    static let empty = SystemSnapshot(
        storageTotal: 0,
        storageAvailable: 0,
        memoryTotal: 0,
        memoryUsed: 0,
        capturedAt: .distantPast
    )

    private func fraction(_ value: Int64, of total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(max(Double(value) / Double(total), 0), 1)
    }
}
