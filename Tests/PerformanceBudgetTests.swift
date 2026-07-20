// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import SpruceMyMac

final class PerformanceBudgetTests: XCTestCase {
    func testDecodesFiveThousandEngineEventsWithinBudget() throws {
        let decoder = NDJSONEventDecoder()
        let line = #"{"type":"progress","completed":4,"total":12}"#
        let clock = ContinuousClock()

        let elapsed = try clock.measure {
            for _ in 0..<5_000 {
                _ = try decoder.decode(line: line)
            }
        }

        XCTAssertLessThan(elapsed, .seconds(2))
    }

    func testSystemSnapshotCompletesWithinBudget() async {
        let monitor = SystemMonitor()
        let clock = ContinuousClock()

        let elapsed = await clock.measure {
            _ = await monitor.snapshot()
        }

        XCTAssertLessThan(elapsed, .seconds(2))
    }
}
