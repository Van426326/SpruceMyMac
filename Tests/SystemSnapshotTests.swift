// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import SpruceMyMac

final class SystemSnapshotTests: XCTestCase {
    func testUsageFractionsAreCalculatedAndClamped() {
        let snapshot = SystemSnapshot(
            storageTotal: 100,
            storageAvailable: 25,
            memoryTotal: 10,
            memoryUsed: 12,
            capturedAt: .now
        )

        XCTAssertEqual(snapshot.storageUsageFraction, 0.75)
        XCTAssertEqual(snapshot.memoryUsageFraction, 1)
    }

    func testByteFormattingNeverDisplaysNegativeValues() {
        XCTAssertEqual(ByteFormatting.string(-1), ByteFormatting.string(0))
    }
}
