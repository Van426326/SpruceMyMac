// SPDX-License-Identifier: GPL-3.0-only

import Foundation

actor UserCacheScanner {
    struct Result: Sendable {
        let candidates: [CleanupCandidate]
        let skippedItemCount: Int
    }

    func scan() async -> Result {
        let fileManager = FileManager()
        let protectedPaths = await ProtectionRuleStore.shared.rules().map(\.path)
        let cacheRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)

        guard let children = try? fileManager.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return Result(candidates: [], skippedItemCount: 1)
        }

        var candidates: [CleanupCandidate] = []
        var skipped = 0

        for child in children {
            if Task.isCancelled { break }
            if protectedPaths.contains(where: { child.path == $0 || child.path.hasPrefix($0 + "/") }) {
                skipped += 1
                continue
            }
            guard let fingerprint = FileFingerprint.capture(at: child, fileManager: fileManager),
                  let size = allocatedSize(of: child, fileManager: fileManager) else {
                skipped += 1
                continue
            }
            guard size > 0 else { continue }

            candidates.append(
                CleanupCandidate(
                    id: child.path,
                    name: displayName(for: child),
                    path: child.path,
                    size: size,
                    category: .applicationCache,
                    risk: .safe,
                    fingerprint: fingerprint,
                    isSelected: false
                )
            )
        }

        return Result(
            candidates: candidates.sorted { $0.size > $1.size },
            skippedItemCount: skipped
        )
    }

    private func allocatedSize(of root: URL, fileManager: FileManager) -> Int64? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return nil
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if Task.isCancelled { return nil }
            guard let values = try? fileURL.resourceValues(forKeys: keys), values.isRegularFile == true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    private func displayName(for url: URL) -> String {
        let rawName = url.lastPathComponent
        return rawName
            .replacingOccurrences(of: "com.", with: "")
            .replacingOccurrences(of: ".", with: " · ")
    }
}
