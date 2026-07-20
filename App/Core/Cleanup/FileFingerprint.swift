// SPDX-License-Identifier: GPL-3.0-only

import Foundation

struct FileFingerprint: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let modifiedAt: Int64

    static func capture(
        at url: URL,
        fileManager: FileManager = FileManager()
    ) -> FileFingerprint? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType != .typeSymbolicLink,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }

        return FileFingerprint(
            device: device.uint64Value,
            inode: inode.uint64Value,
            modifiedAt: Int64(modificationDate.timeIntervalSince1970)
        )
    }
}
