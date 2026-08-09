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
        let ready = directory.appendingPathComponent("ready")
        let script = """
        #!/bin/bash
        printf ready > '\(ready.path)'
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
        try await waitForFile(ready)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to stop the engine process")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testCancellingOneConcurrentOperationDoesNotTerminateAnother() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpruceConcurrentBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("concurrent-fixture-engine")
        let cleanReady = directory.appendingPathComponent("clean-ready")
        let appReady = directory.appendingPathComponent("app-ready")
        let script = """
        #!/bin/bash
        if [[ "$1" == "clean-plan" ]]; then
          printf ready > '\(cleanReady.path)'
          printf '%s\\n' '{"type":"started","protocol":1,"operation":"clean","plan_id":"clean-plan","expires_at":1784490000}'
          exec sleep 30
        fi
        printf ready > '\(appReady.path)'
        sleep 0.15
        printf '%s\\n' '{"type":"started","protocol":1,"operation":"app_list","plan_id":"inventory","expires_at":1784490000}'
        printf '%s\\n' '{"type":"completed","plan_id":"inventory","freed_bytes":0,"candidate_count":0}'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let bridge = BundledMoleBridge(executableURL: executable)
        let cleanTask = Task { try await bridge.cleanPlanEvents() }
        try await waitForFile(cleanReady)
        let appTask = Task { try await bridge.applicationListEvents() }
        try await waitForFile(appReady)
        cleanTask.cancel()

        do {
            _ = try await cleanTask.value
            XCTFail("Expected clean task cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let appEvents = try await appTask.value
        XCTAssertEqual(appEvents.count, 2)
    }

    func testCancelledApplyStillReturnsTerminalResults() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpruceApplyCancellationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("apply-cancellation-fixture")
        let firstResultReady = directory.appendingPathComponent("first-result-ready")
        let planID = UUID().uuidString.lowercased()
        let firstID = String(repeating: "a", count: 64)
        let secondID = String(repeating: "b", count: 64)
        let script = """
        #!/bin/bash
        printf '%s\\n' '{"type":"started","protocol":1,"operation":"apply_clean","plan_id":"\(planID)","expires_at":1784490000}'
        printf '%s\\n' '{"type":"item_result","plan_id":"\(planID)","id":"\(firstID)","status":"trashed","bytes":1024,"error_code":""}'
        printf ready > '\(firstResultReady.path)'
        sleep 0.15
        printf '%s\\n' '{"type":"item_result","plan_id":"\(planID)","id":"\(secondID)","status":"trashed","bytes":2048,"error_code":""}'
        printf '%s\\n' '{"type":"completed","plan_id":"\(planID)","freed_bytes":3072,"candidate_count":2,"failed_count":0}'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let bridge = BundledMoleBridge(executableURL: executable)
        let task = Task { try await bridge.applyPlanEvents(planID: planID, candidateIDs: [firstID, secondID]) }
        try await waitForFile(firstResultReady)
        task.cancel()

        let events = try await task.value
        XCTAssertEqual(events.count, 4)
        guard case let .completed(completion) = events.last else {
            return XCTFail("Expected a terminal completion event")
        }
        XCTAssertEqual(completion.candidateCount, 2)
        XCTAssertEqual(completion.freedBytes, 3072)
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

    func testResolvesEngineDynamicallyForEachOperation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpruceDynamicBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let first = try makeCleanFixture(in: directory, name: "first", planID: "first-plan")
        let second = try makeCleanFixture(in: directory, name: "second", planID: "second-plan")
        let resolver = SwitchingEngineResolver(executableURL: first, version: try EngineVersion("1.0.0"))
        let bridge = BundledMoleBridge(resolver: resolver)

        let firstEvents = try await bridge.cleanPlanEvents()
        await resolver.switchTo(executableURL: second, version: try EngineVersion("1.1.0"))
        let secondEvents = try await bridge.cleanPlanEvents()

        guard case let .started(firstHeader) = firstEvents.first,
              case let .started(secondHeader) = secondEvents.first else {
            return XCTFail("Expected started events")
        }
        XCTAssertEqual(firstHeader.planID, "first-plan")
        XCTAssertEqual(secondHeader.planID, "second-plan")
        let resolveCount = await resolver.resolveCount()
        XCTAssertEqual(resolveCount, 2)
    }

    private func waitForFile(_ url: URL, timeout: Duration = .seconds(3)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for fixture readiness: \(url.lastPathComponent)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeCleanFixture(in directory: URL, name: String, planID: String) throws -> URL {
        let executable = directory.appendingPathComponent(name)
        let script = """
        #!/bin/bash
        printf '%s\\n' '{"type":"started","protocol":1,"operation":"clean","plan_id":"\(planID)","expires_at":1784490000}'
        printf '%s\\n' '{"type":"completed","plan_id":"\(planID)","freed_bytes":0,"candidate_count":0}'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
}

private actor SwitchingEngineResolver: EngineResolving {
    private var executableURL: URL
    private var version: EngineVersion
    private var count = 0

    init(executableURL: URL, version: EngineVersion) {
        self.executableURL = executableURL
        self.version = version
    }

    func resolve() -> ResolvedEngine {
        count += 1
        return ResolvedEngine(
            executableURL: executableURL,
            version: version,
            upstreamCommit: String(repeating: "a", count: 40),
            provenance: .downloaded,
            sourceURL: nil
        )
    }

    func switchTo(executableURL: URL, version: EngineVersion) {
        self.executableURL = executableURL
        self.version = version
    }

    func resolveCount() -> Int { count }
}
