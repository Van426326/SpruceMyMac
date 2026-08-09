// SPDX-License-Identifier: GPL-3.0-only

import Foundation

struct CleanupHistoryRecord: Codable, Identifiable, Equatable, Sendable {
    enum Operation: String, Codable, Sendable {
        case cleanup
        case uninstall
        case analyzer
        case toolbox
        case maintenance
    }

    enum Outcome: String, Codable, Sendable {
        case completed
        case partial
        case failed
    }

    let id: UUID
    let operation: Operation
    let planID: String
    let finishedAt: Date
    let selectedCount: Int
    let succeededCount: Int
    let failedCount: Int
    let freedBytes: Int64
    let outcome: Outcome

    static func make(
        plan: CleanupPlan,
        events: [EngineEvent],
        finishedAt: Date = Date()
    ) -> CleanupHistoryRecord {
        let itemResults = events.compactMap { event -> EngineItemResult? in
            guard case let .itemResult(result) = event else { return nil }
            return result
        }
        let completion = events.compactMap { event -> EngineCompletion? in
            guard case let .completed(completion) = event else { return nil }
            return completion
        }.last
        let succeeded = itemResults.filter { $0.status == "trashed" }.count
        let failed = completion?.failedCount ?? itemResults.filter { $0.status != "trashed" }.count
        let outcome: Outcome = if succeeded == 0 && failed > 0 {
            .failed
        } else if failed > 0 {
            .partial
        } else {
            .completed
        }

        return CleanupHistoryRecord(
            id: UUID(),
            operation: .cleanup,
            planID: plan.enginePlanID ?? plan.id.uuidString.lowercased(),
            finishedAt: finishedAt,
            selectedCount: plan.candidates.count,
            succeededCount: succeeded,
            failedCount: failed,
            freedBytes: completion?.freedBytes ?? itemResults.reduce(0) { $0 + $1.bytes },
            outcome: outcome
        )
    }

    static func make(
        operation: Operation,
        planID: String,
        selectedCount: Int,
        events: [EngineEvent],
        finishedAt: Date = Date()
    ) -> CleanupHistoryRecord {
        let itemResults = events.compactMap { event -> EngineItemResult? in
            guard case let .itemResult(result) = event else { return nil }
            return result
        }
        let completion = events.compactMap { event -> EngineCompletion? in
            guard case let .completed(completion) = event else { return nil }
            return completion
        }.last
        let succeeded = itemResults.filter { $0.status == "trashed" }.count
        let failed = completion?.failedCount ?? itemResults.filter { $0.status != "trashed" }.count
        let outcome: Outcome = if succeeded == 0 && failed > 0 {
            .failed
        } else if failed > 0 {
            .partial
        } else {
            .completed
        }

        return CleanupHistoryRecord(
            id: UUID(),
            operation: operation,
            planID: planID,
            finishedAt: finishedAt,
            selectedCount: selectedCount,
            succeededCount: succeeded,
            failedCount: failed,
            freedBytes: completion?.freedBytes ?? itemResults.reduce(0) { $0 + $1.bytes },
            outcome: outcome
        )
    }
}

actor CleanupHistoryStore {
    static let shared = CleanupHistoryStore()

    private let directoryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SpruceMyMac", isDirectory: true),
        fileManager: FileManager = FileManager()
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func records() -> [CleanupHistoryRecord] {
        let fileURL = directoryURL.appendingPathComponent("history.json")
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? decoder.decode([CleanupHistoryRecord].self, from: data) else {
            return []
        }
        return records.sorted { $0.finishedAt > $1.finishedAt }
    }

    func append(_ record: CleanupHistoryRecord) throws {
        try ensureDirectory()
        var current = records()
        current.insert(record, at: 0)
        if current.count > 200 {
            current.removeLast(current.count - 200)
        }
        let data = try encoder.encode(current)
        let historyURL = directoryURL.appendingPathComponent("history.json")
        try data.write(to: historyURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: historyURL.path
        )
    }

    func removeAll() throws {
        let fileURL = directoryURL.appendingPathComponent("history.json")
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private func ensureDirectory() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                  (try? directoryURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        } else {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }
}
