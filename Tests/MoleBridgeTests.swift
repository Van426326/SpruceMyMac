// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import XCTest
@testable import SpruceMyMac

final class MoleBridgeTests: XCTestCase {
    func testReadsNDJSONFromEngineProcess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpruceMyMacBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fixture-engine")
        let script = """
        #!/bin/bash
        printf '%s\\n' '{"type":"started","protocol":1,"operation":"clean","plan_id":"fixture","expires_at":1784490000}'
        printf '%s\\n' '{"type":"progress","completed":1,"total":1}'
        printf '%s\\n' '{"type":"completed","plan_id":"fixture","freed_bytes":0,"candidate_count":0}'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let bridge = BundledMoleBridge(executableURL: executable)
        let events = try await bridge.cleanPlanEvents()

        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(
            events.first,
            .started(
                EnginePlanHeader(
                    protocolVersion: 1,
                    operation: "clean",
                    planID: "fixture",
                    expiresAt: Date(timeIntervalSince1970: 1_784_490_000)
                )
            )
        )
    }

    func testCancellationTerminatesEngineProcess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpruceMyMacBridgeCancelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("slow-fixture-engine")
        let script = """
        #!/bin/bash
        printf '%s\\n' '{"type":"started","protocol":1,"operation":"clean","plan_id":"fixture","expires_at":1784490000}'
        exec sleep 30
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let bridge = BundledMoleBridge(executableURL: executable)
        let task = Task {
            try await bridge.cleanPlanEvents()
        }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to stop the engine process")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testAppliesOnlyValidatedCandidateIDs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpruceMyMacBridgeApplyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("apply-fixture-engine")
        let planID = UUID().uuidString.lowercased()
        let candidateID = String(repeating: "a", count: 64)
        let script = """
        #!/bin/bash
        printf '%s\\n' '{"type":"started","protocol":1,"operation":"apply_clean","plan_id":"\(planID)","expires_at":1784490000}'
        printf '%s\\n' '{"type":"item_result","plan_id":"\(planID)","id":"\(candidateID)","status":"trashed","bytes":4096,"error_code":""}'
        printf '%s\\n' '{"type":"completed","plan_id":"\(planID)","freed_bytes":4096,"candidate_count":1,"failed_count":0}'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let bridge = BundledMoleBridge(executableURL: executable)
        let events = try await bridge.applyPlanEvents(planID: planID, candidateIDs: [candidateID])

        XCTAssertEqual(events.count, 3)
    }

    func testRejectsInvalidApplyRequestBeforeLaunchingProcess() async throws {
        let bridge = BundledMoleBridge(executableURL: URL(fileURLWithPath: "/does/not/exist"))

        do {
            _ = try await bridge.applyPlanEvents(planID: "not-a-plan", candidateIDs: ["bad"])
            XCTFail("Expected invalid IDs to be rejected")
        } catch let error as EngineProtocolError {
            XCTAssertEqual(error, .invalidRequest)
        }
    }
}
