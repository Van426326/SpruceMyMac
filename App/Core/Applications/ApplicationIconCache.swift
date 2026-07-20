// SPDX-License-Identifier: GPL-3.0-only

import AppKit

@MainActor
final class ApplicationIconCache {
    static let shared = ApplicationIconCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 256
        cache.totalCostLimit = 32 * 1_024 * 1_024
    }

    func icon(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 64, height: 64)
        cache.setObject(icon, forKey: key, cost: 64 * 64 * 4)
        return icon
    }
}
