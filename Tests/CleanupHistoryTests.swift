// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import XCTest
@testable import SpruceMyMac

final class CleanupHistoryTests: XCTestCase {
    func testPersistsAndLoadsNewestRecordFirst() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpruceMyMacHistoryTests-\(UUID().uuidString)", isDirectory: true)
        let store = CleanupHistoryStore(directoryURL: directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let older = makeRecord(date: Date(timeIntervalSince1970: 1))
        let newer = makeRecord(date: Date(timeIntervalSince1970: 2))
        try await store.append(older)
        try await store.append(newer)

        let records = await store.records()
        XCTAssertEqual(records.map(\.id), [newer.id, older.id])
    }

    func testBuildsPartialOutcomeFromEngineResults() throws {
        let plan = CleanupPlan(candidates: [])
        let events: [EngineEvent] = [
            .itemResult(EngineItemResult(planID: "plan", id: "one", status: "trashed", bytes: 100, errorCode: nil)),
            .itemResult(EngineItemResult(planID: "plan", id: "two", status: "failed", bytes: 0, errorCode: "trash_unavailable")),
            .completed(EngineCompletion(planID: "plan", freedBytes: 100, candidateCount: 2, failedCount: 1))
        ]

        let record = CleanupHistoryRecord.make(plan: plan, events: events)

        XCTAssertEqual(record.outcome, .partial)
        XCTAssertEqual(record.succeededCount, 1)
        XCTAssertEqual(record.failedCount, 1)
        XCTAssertEqual(record.freedBytes, 100)
    }

    func testPersistsMaintenanceOperation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpruceMyMacMaintenanceHistory-\(UUID().uuidString)", isDirectory: true)
        let store = CleanupHistoryStore(directoryURL: directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let record = CleanupHistoryRecord(
            id: UUID(),
            operation: .maintenance,
            planID: UUID().uuidString.lowercased(),
            finishedAt: Date(),
            selectedCount: 1,
            succeededCount: 1,
            failedCount: 0,
            freedBytes: 0,
            outcome: .completed
        )

        try await store.append(record)

        let records = await store.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, record.id)
        XCTAssertEqual(records.first?.operation, .maintenance)
        XCTAssertEqual(records.first?.planID, record.planID)
    }

    private func makeRecord(date: Date) -> CleanupHistoryRecord {
        CleanupHistoryRecord(
            id: UUID(),
            operation: .cleanup,
            planID: UUID().uuidString,
            finishedAt: date,
            selectedCount: 1,
            succeededCount: 1,
            failedCount: 0,
            freedBytes: 1,
            outcome: .completed
        )
    }
}
