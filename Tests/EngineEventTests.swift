// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import SpruceMyMac

final class EngineEventTests: XCTestCase {
    private let decoder = NDJSONEventDecoder()

    func testDecodesStartedEvent() throws {
        let event = try decoder.decode(
            line: #"{"type":"started","protocol":1,"operation":"clean","plan_id":"plan-1","expires_at":1784490000}"#
        )

        XCTAssertEqual(
            event,
            .started(
                EnginePlanHeader(
                    protocolVersion: 1,
                    operation: "clean",
                    planID: "plan-1",
                    expiresAt: Date(timeIntervalSince1970: 1_784_490_000)
                )
            )
        )
    }

    func testDecodesCandidateEvent() throws {
        let event = try decoder.decode(
            line: #"{"type":"candidate","plan_id":"plan-1","id":"browser.chrome.cache","name":"Chrome","path":"/Users/test/Library/Caches/Chrome","size":82433821,"category":"browser","risk":"review","requires_root":false,"reversible":false,"device":1,"inode":2,"modified_at":3}"#
        )

        XCTAssertEqual(
            event,
            .candidate(
                EngineCandidate(
                    planID: "plan-1",
                    id: "browser.chrome.cache",
                    name: "Chrome",
                    path: "/Users/test/Library/Caches/Chrome",
                    size: 82_433_821,
                    category: "browser",
                    risk: "review",
                    requiresRoot: false,
                    reversible: false,
                    device: 1,
                    inode: 2,
                    modifiedAt: 3
                )
            )
        )
    }

    func testDecodesProgressAndCompletionEvents() throws {
        XCTAssertEqual(
            try decoder.decode(line: #"{"type":"progress","completed":4,"total":12}"#),
            .progress(completed: 4, total: 12)
        )
        XCTAssertEqual(
            try decoder.decode(line: #"{"type":"completed","freed_bytes":82433821}"#),
            .completed(
                EngineCompletion(
                    planID: nil,
                    freedBytes: 82_433_821,
                    candidateCount: nil,
                    failedCount: nil
                )
            )
        )
    }

    func testDecodesApplyItemResult() throws {
        XCTAssertEqual(
            try decoder.decode(
                line: #"{"type":"item_result","plan_id":"plan-1","id":"candidate-1","status":"trashed","bytes":4096,"error_code":""}"#
            ),
            .itemResult(
                EngineItemResult(
                    planID: "plan-1",
                    id: "candidate-1",
                    status: "trashed",
                    bytes: 4_096,
                    errorCode: ""
                )
            )
        )
    }

    func testDecodesApplicationInventoryAndUninstallCandidate() throws {
        XCTAssertEqual(
            try decoder.decode(
                line: #"{"type":"application","inventory_id":"inventory","id":"app","name":"Example","path":"/Applications/Example.app","bundle_id":"com.example.app","size":1024,"source":"Application","protected":false,"device":1,"inode":2,"modified_at":3}"#
            ),
            .application(
                EngineApplication(
                    inventoryID: "inventory",
                    id: "app",
                    name: "Example",
                    path: "/Applications/Example.app",
                    bundleID: "com.example.app",
                    size: 1_024,
                    source: "Application",
                    isProtected: false,
                    device: 1,
                    inode: 2,
                    modifiedAt: 3
                )
            )
        )

        XCTAssertEqual(
            try decoder.decode(
                line: #"{"type":"uninstall_candidate","plan_id":"plan","id":"item","name":"Example.app","path":"/Applications/Example.app","size":1024,"category":"application","risk":"review","default_selected":true,"requires_root":false,"reversible":true,"device":1,"inode":2,"modified_at":3}"#
            ),
            .uninstallCandidate(
                EngineUninstallCandidate(
                    planID: "plan",
                    id: "item",
                    name: "Example.app",
                    path: "/Applications/Example.app",
                    size: 1_024,
                    category: "application",
                    risk: "review",
                    defaultSelected: true,
                    requiresRoot: false,
                    reversible: true,
                    device: 1,
                    inode: 2,
                    modifiedAt: 3
                )
            )
        )
    }
}
