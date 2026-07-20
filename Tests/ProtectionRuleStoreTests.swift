// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import XCTest
@testable import SpruceMyMac

final class ProtectionRuleStoreTests: XCTestCase {
    func testPersistsRulesAndProtectsDescendants() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpruceMyMacRulesTests-\(UUID().uuidString)", isDirectory: true)
        let protected = directory.appendingPathComponent("Protected", isDirectory: true)
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        let store = ProtectionRuleStore(directoryURL: directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        try await store.add(protected)

        let paths = await store.rules().map(\.path)
        let protectsChild = await store.isProtected(protected.appendingPathComponent("child.cache"))
        XCTAssertEqual(paths, [protected.path])
        XCTAssertTrue(protectsChild)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("whitelist").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRejectsFilesystemRoot() async throws {
        let store = ProtectionRuleStore(directoryURL: FileManager.default.temporaryDirectory)
        do {
            try await store.add(URL(fileURLWithPath: "/"))
            XCTFail("Expected root to be rejected")
        } catch let error as ProtectionRuleStore.RuleError {
            XCTAssertEqual(error, .invalidPath)
        }
    }
}
