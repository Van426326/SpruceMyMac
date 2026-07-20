// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import SpruceMyMac

final class SystemMaintenanceCommandTests: XCTestCase {
    func testCommandAssistantExposesOnlyAuditedFixedCommands() {
        XCTAssertEqual(
            SystemMaintenanceCommand.all.map(\.command),
            [
                "sudo /usr/bin/dscacheutil -flushcache\nsudo /usr/bin/killall -HUP mDNSResponder",
                "sudo /usr/bin/mdutil -E /"
            ]
        )
    }

    func testCommandsContainNoShellInterpolation() {
        for command in SystemMaintenanceCommand.all {
            XCTAssertFalse(command.command.contains("$("))
            XCTAssertFalse(command.command.contains("`"))
            XCTAssertFalse(command.command.contains("${"))
        }
    }
}
