// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import SpruceMyMac

final class LocalizationResourceTests: XCTestCase {
    func testEnglishFallbackIsCompiledIntoApplicationBundle() throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let englishURL = resources.appendingPathComponent("en.lproj", isDirectory: true)
        let englishBundle = try XCTUnwrap(Bundle(url: englishURL))

        XCTAssertEqual(
            englishBundle.localizedString(forKey: "概览", value: nil, table: nil),
            "Overview"
        )
        XCTAssertEqual(
            englishBundle.localizedString(forKey: "建议检查", value: nil, table: nil),
            "Review suggested"
        )
        XCTAssertEqual(
            englishBundle.localizedString(forKey: "智能清理", value: nil, table: nil),
            "Smart Cleanup"
        )
    }

    func testSimplifiedChineseSourceIsCompiledIntoApplicationBundle() throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let chineseURL = resources.appendingPathComponent("zh-Hans.lproj", isDirectory: true)
        let chineseBundle = try XCTUnwrap(Bundle(url: chineseURL))

        XCTAssertEqual(
            chineseBundle.localizedString(forKey: "概览", value: nil, table: nil),
            "概览"
        )
    }
}
