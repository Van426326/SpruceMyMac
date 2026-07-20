// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation

struct InstalledApplication: Identifiable, Hashable {
    let id: String
    let inventoryID: String
    let name: String
    let path: String
    let bundleID: String
    let size: Int64
    let source: String
    let isProtected: Bool
    let lastUsedAt: Date?

    init(_ application: EngineApplication) {
        id = application.id
        inventoryID = application.inventoryID
        name = application.name
        path = application.path
        bundleID = application.bundleID
        size = application.size
        source = application.source
        isProtected = application.isProtected
        lastUsedAt = try? URL(fileURLWithPath: application.path)
            .resourceValues(forKeys: [.contentAccessDateKey])
            .contentAccessDate
    }

    @MainActor
    var icon: NSImage {
        ApplicationIconCache.shared.icon(for: path)
    }

    var sourceTitle: String {
        source == "User" ? String(localized: "用户应用") : String(localized: "应用程序")
    }
}
