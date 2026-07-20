// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import XCTest
@testable import SpruceMyMac

final class SpaceAnalyzerTests: XCTestCase {
    func testStreamsLargeRegularFilesAndSkipsSymlinks() async throws {
        let root = try makeDirectory()
        let largeFile = root.appendingPathComponent("archive.dmg")
        try Data(repeating: 0x41, count: 256 * 1_024).write(to: largeFile)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.dmg"),
            withDestinationURL: largeFile
        )

        let analyzer = SpaceAnalyzer()
        var candidates: [AnalyzedFile] = []
        for await progress in await analyzer.scan(root: root, minimumSize: 1) {
            if let candidate = progress.candidate { candidates.append(candidate) }
        }

        XCTAssertEqual(candidates.map(\.name), ["archive.dmg"])
        XCTAssertEqual(candidates.first?.category, .installer)
    }

    func testTrashValidationRejectsFileOutsideSelectedRoot() async throws {
        let root = try makeDirectory()
        let outsideRoot = try makeDirectory()
        let fileURL = outsideRoot.appendingPathComponent("large.mov")
        try Data("fixture".utf8).write(to: fileURL)
        let fingerprint = try XCTUnwrap(FileFingerprint.capture(at: fileURL))
        let file = AnalyzedFile(
            id: "outside",
            url: fileURL,
            size: 7,
            modifiedAt: Date(),
            category: .video,
            fingerprint: fingerprint
        )

        let service = AnalyzerTrashService()
        let result = await service.validate(file, under: root)

        guard case let .failure(error) = result else {
            return XCTFail("Expected an outside-root failure")
        }
        XCTAssertEqual(error, .outsideRoot)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpruceMyMacAnalyzerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
