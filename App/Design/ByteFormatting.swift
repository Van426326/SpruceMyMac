// SPDX-License-Identifier: GPL-3.0-only

import Foundation

enum ByteFormatting {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}
