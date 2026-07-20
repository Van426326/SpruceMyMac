// SPDX-License-Identifier: GPL-3.0-only

import Foundation

actor SpaceAnalyzer {
    struct Progress: Sendable {
        let scannedFileCount: Int
        let scannedBytes: Int64
        let candidate: AnalyzedFile?
    }

    func scan(
        root: URL,
        minimumSize: Int64 = 20 * 1_024 * 1_024
    ) -> AsyncStream<Progress> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let fileManager = FileManager()
                let keys: [URLResourceKey] = [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileAllocatedSizeKey,
                    .totalFileAllocatedSizeKey,
                    .contentModificationDateKey
                ]
                guard let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, _ in true }
                ) else {
                    continuation.finish()
                    return
                }

                var scannedCount = 0
                var scannedBytes: Int64 = 0
                while let url = enumerator.nextObject() as? URL {
                    if Task.isCancelled { break }
                    guard let values = try? url.resourceValues(forKeys: Set(keys)),
                          values.isRegularFile == true,
                          values.isSymbolicLink != true else {
                        continue
                    }

                    let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                    scannedCount += 1
                    scannedBytes += max(0, size)
                    var candidate: AnalyzedFile?
                    if size >= minimumSize,
                       let fingerprint = FileFingerprint.capture(at: url) {
                        candidate = AnalyzedFile(
                            id: "\(fingerprint.device):\(fingerprint.inode)",
                            url: url,
                            size: size,
                            modifiedAt: values.contentModificationDate ?? .distantPast,
                            category: AnalyzedFile.category(for: url),
                            fingerprint: fingerprint
                        )
                    }

                    if candidate != nil || scannedCount.isMultiple(of: 100) {
                        continuation.yield(
                            Progress(
                                scannedFileCount: scannedCount,
                                scannedBytes: scannedBytes,
                                candidate: candidate
                            )
                        )
                    }
                }
                continuation.yield(Progress(scannedFileCount: scannedCount, scannedBytes: scannedBytes, candidate: nil))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

actor AnalyzerTrashService {
    enum ValidationError: Error, Equatable {
        case outsideRoot
        case changed
        case notRegularFile
    }

    private let protectionStore = ProtectionRuleStore.shared

    func validate(_ file: AnalyzedFile, under root: URL) async -> Result<Void, ValidationError> {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedFile = file.url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedFile.hasPrefix(resolvedRoot + "/") else { return .failure(.outsideRoot) }
        guard FileFingerprint.capture(at: file.url) == file.fingerprint else { return .failure(.changed) }
        guard !(await protectionStore.isProtected(file.url)) else { return .failure(.outsideRoot) }
        guard (try? file.url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return .failure(.notRegularFile)
        }
        return .success(())
    }

    func moveToTrash(_ file: AnalyzedFile, under root: URL) async throws {
        guard case .success = await validate(file, under: root) else {
            throw ValidationError.changed
        }
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: file.url, resultingItemURL: &resultingURL)
    }
}
