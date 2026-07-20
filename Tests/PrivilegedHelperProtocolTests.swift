// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import XCTest
@testable import SpruceMyMac

final class PrivilegedHelperProtocolTests: XCTestCase {
    func testCatalogContainsOnlyFixedAbsoluteCommands() throws {
        XCTAssertEqual(
            Set(SystemMaintenanceTaskCatalog.taskIdentifiers),
            Set(["flush-dns-cache", "rebuild-spotlight-index"])
        )

        for definition in SystemMaintenanceTaskCatalog.definitions {
            XCTAssertFalse(definition.commands.isEmpty)
            for command in definition.commands {
                XCTAssertTrue(command.executablePath.hasPrefix("/usr/bin/"))
                XCTAssertFalse(command.executablePath.contains(".."))
                XCTAssertFalse(["sh", "bash", "zsh", "env"].contains(
                    URL(fileURLWithPath: command.executablePath).lastPathComponent
                ))
                XCTAssertGreaterThan(command.timeoutSeconds, 0)
                XCTAssertLessThanOrEqual(command.timeoutSeconds, 30)
            }
        }
    }

    func testCatalogCommandsMatchAuditedArgumentVectors() throws {
        let dns = try XCTUnwrap(SystemMaintenanceTaskCatalog.definition(for: "flush-dns-cache"))
        XCTAssertEqual(dns.commands, [
            FixedSystemCommand(
                executablePath: "/usr/bin/dscacheutil",
                arguments: ["-flushcache"],
                timeoutSeconds: 10
            ),
            FixedSystemCommand(
                executablePath: "/usr/bin/killall",
                arguments: ["-HUP", "mDNSResponder"],
                timeoutSeconds: 10
            )
        ])

        let spotlight = try XCTUnwrap(
            SystemMaintenanceTaskCatalog.definition(for: "rebuild-spotlight-index")
        )
        XCTAssertEqual(spotlight.commands, [
            FixedSystemCommand(
                executablePath: "/usr/bin/mdutil",
                arguments: ["-E", "/"],
                timeoutSeconds: 30
            )
        ])
    }

    func testValidatorRejectsUnknownTasksAndMalformedRequestIDs() throws {
        XCTAssertNil(PrivilegedRequestValidator.task(for: "flush-dns-cache;rm"))
        XCTAssertNil(PrivilegedRequestValidator.task(for: "arbitrary-command"))
        XCTAssertNil(PrivilegedRequestValidator.canonicalRequestIdentifier("not-a-uuid"))

        let identifier = UUID().uuidString.lowercased()
        XCTAssertEqual(
            PrivilegedRequestValidator.canonicalRequestIdentifier(identifier),
            identifier
        )
    }

    func testResultParserAcceptsBoundedMatchingPayload() throws {
        let requestIdentifier = UUID().uuidString.lowercased()
        let payload: NSDictionary = [
            "protocol": SprucePrivilegedHelperConstants.protocolVersion,
            "request_id": requestIdentifier,
            "task_id": SystemMaintenanceTask.flushDNSCache.rawValue,
            "succeeded": true,
            "started_at": 100.0,
            "finished_at": 101.0,
            "exit_codes": [NSNumber(value: 0), NSNumber(value: 0)],
            "message_key": "helper.task.completed"
        ]

        let result = try MaintenanceTaskResult(dictionary: payload)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.requestIdentifier, requestIdentifier)
        XCTAssertEqual(result.exitCodes, [0, 0])
    }

    func testResultParserRejectsProtocolAndTaskInjection() throws {
        let requestIdentifier = UUID().uuidString.lowercased()
        let invalidProtocol: NSDictionary = [
            "protocol": 999,
            "request_id": requestIdentifier,
            "task_id": SystemMaintenanceTask.flushDNSCache.rawValue,
            "succeeded": true,
            "started_at": 100.0,
            "finished_at": 101.0,
            "exit_codes": [NSNumber(value: 0)],
            "message_key": "helper.task.completed"
        ]
        XCTAssertThrowsError(try MaintenanceTaskResult(dictionary: invalidProtocol))

        let injectedTask = invalidProtocol.mutableCopy() as! NSMutableDictionary
        injectedTask["protocol"] = SprucePrivilegedHelperConstants.protocolVersion
        injectedTask["task_id"] = "flush-dns-cache;touch-/tmp/pwned"
        XCTAssertThrowsError(try MaintenanceTaskResult(dictionary: injectedTask))

        injectedTask["task_id"] = SystemMaintenanceTask.flushDNSCache.rawValue
        injectedTask["message_key"] = "untrusted.message"
        XCTAssertThrowsError(try MaintenanceTaskResult(dictionary: injectedTask))
    }
}
