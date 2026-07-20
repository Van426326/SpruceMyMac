// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import XCTest
@testable import SpruceMyMac

final class CleanupPlanTests: XCTestCase {
    func testValidatesUnchangedCandidateInsideAllowedRoot() async throws {
        let fixture = try makeFixture()
        let candidate = try makeCandidate(at: fixture.candidate)
        let plan = CleanupPlan(candidates: [candidate])
        let validator = CleanupPlanValidator(allowedRoot: fixture.root)

        let result = await validator.validate(plan)

        guard case .success = result else {
            return XCTFail("Expected an unchanged cache candidate to validate")
        }
    }

    func testRejectsCandidateOutsideAllowedRoot() async throws {
        let allowedFixture = try makeFixture()
        let outsideFixture = try makeFixture()
        let candidate = try makeCandidate(at: outsideFixture.candidate)
        let plan = CleanupPlan(candidates: [candidate])
        let validator = CleanupPlanValidator(allowedRoot: allowedFixture.root)

        let result = await validator.validate(plan)

        XCTAssertEqual(result.failure, .pathOutsideAllowedRoot)
    }

    func testRejectsExpiredPlan() async throws {
        let fixture = try makeFixture()
        let candidate = try makeCandidate(at: fixture.candidate)
        let now = Date()
        let plan = CleanupPlan(candidates: [candidate], now: now, lifetime: -1)
        let validator = CleanupPlanValidator(allowedRoot: fixture.root)

        let result = await validator.validate(plan, now: now)

        XCTAssertEqual(result.failure, .expired)
    }

    private func makeFixture() throws -> (root: URL, candidate: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpruceMyMacTests-\(UUID().uuidString)", isDirectory: true)
        let candidate = root.appendingPathComponent("com.example.cache", isDirectory: true)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        let data = candidate.appendingPathComponent("cache.data")
        try Data("fixture".utf8).write(to: data)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return (root, candidate)
    }

    private func makeCandidate(at url: URL) throws -> CleanupCandidate {
        let fingerprint = try XCTUnwrap(FileFingerprint.capture(at: url))
        return CleanupCandidate(
            id: url.path,
            name: url.lastPathComponent,
            path: url.path,
            size: 7,
            category: .applicationCache,
            risk: .safe,
            fingerprint: fingerprint,
            isSelected: true
        )
    }
}

private extension Result {
    var failure: Failure? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}
