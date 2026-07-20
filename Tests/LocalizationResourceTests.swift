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
        XCTAssertEqual(
            String(
                localized: "概览",
                bundle: .main,
                locale: Locale(identifier: "zh-Hans")
            ),
            "概览"
        )
    }
}
