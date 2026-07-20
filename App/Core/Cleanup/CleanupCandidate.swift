// SPDX-License-Identifier: GPL-3.0-only

import Foundation

struct CleanupCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let size: Int64
    let category: Category
    let risk: Risk
    let fingerprint: FileFingerprint
    var isSelected: Bool

    enum Category: String, Sendable {
        case applicationCache

        var title: String { String(localized: "应用缓存") }
    }

    enum Risk: String, Sendable {
        case safe
        case review

        var title: String {
            switch self {
            case .safe: String(localized: "可安全重建")
            case .review: String(localized: "建议检查")
            }
        }
    }
}
