// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import XCTest
@testable import SpruceMyMac

final class EngineUpdateViewModelTests: XCTestCase {
    func testLiveConfigurationUsesFixedFeedAndSafelyDisablesUnexpandedKey() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpruceLiveConfigTests-\(UUID().uuidString).bundle", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources/Engine/Mole/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.SpruceLiveConfigTests",
            "CFBundleVersion": "42",
            "CFBundlePackageType": "BNDL",
            "SpruceEngineSigningPublicKey": "$(ENGINE_SIGNING_PUBLIC_KEY)"
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contents.appendingPathComponent("Info.plist"))
        let launcher = resources.appendingPathComponent("gui.sh")
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: launcher)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let bundle = try XCTUnwrap(Bundle(url: root))
        let configuration = EngineUpdateConfiguration.live(bundle: bundle)

        XCTAssertEqual(configuration.manifestURL, EngineUpdateConfiguration.liveManifestURL)
        XCTAssertEqual(configuration.signatureURL, EngineUpdateConfiguration.liveSignatureURL)
        XCTAssertEqual(configuration.appBuild, 42)
        XCTAssertEqual(configuration.bundledEngineURL.standardizedFileURL, launcher.standardizedFileURL)
        XCTAssertTrue(configuration.applicationSupportRoot.path.hasSuffix("Application Support/SpruceMyMac"))
        XCTAssertFalse(configuration.updatesEnabled)
        XCTAssertThrowsError(try configuration.validateTrustConfiguration()) {
            XCTAssertEqual($0 as? EngineUpdateError, .updatesDisabled)
        }
    }

    @MainActor
    func testViewModelRefreshInstallRestoreAndSafeDisabledState() async throws {
        let bundled = makeResolved(version: "1.0.0", provenance: .bundled)
        let installed = makeResolved(version: "1.1.0", provenance: .downloaded)
        let service = ViewModelEngineService(current: bundled, installed: installed)
        let model = EngineUpdateViewModel(service: service, updatesEnabled: true)

        await model.refreshCurrent()
        XCTAssertEqual(model.currentEngine, bundled)
        XCTAssertEqual(model.phase, .idle)

        await model.checkForUpdate()
        XCTAssertEqual(model.candidate?.manifest.engineVersion.description, "1.1.0")
        await model.installCandidate()
        XCTAssertEqual(model.currentEngine, installed)
        XCTAssertNil(model.candidate)
        XCTAssertTrue(model.canRestoreBundled)

        await model.restoreBundled()
        XCTAssertEqual(model.currentEngine?.version, bundled.version)
        XCTAssertEqual(model.currentEngine?.provenance, .bundled)
        XCTAssertFalse(model.canRestoreBundled)

        let disabledService = ViewModelEngineService(current: bundled, installed: installed)
        let disabled = EngineUpdateViewModel(service: disabledService, updatesEnabled: false)
        await disabled.checkForUpdate()
        let disabledCheckCalls = await disabledService.checkCallCount()
        XCTAssertEqual(disabledCheckCalls, 0)
        XCTAssertNotNil(disabled.noticeMessage)
    }

    @MainActor
    func testViewModelRejectsOverlappingActionsAndMapsVerificationError() async throws {
        let bundled = makeResolved(version: "1.0.0", provenance: .bundled)
        let service = ViewModelEngineService(
            current: bundled,
            installed: bundled,
            checkDelayNanoseconds: 150_000_000
        )
        let model = EngineUpdateViewModel(service: service, updatesEnabled: true)
        let first = Task { await model.checkForUpdate() }
        try await Task.sleep(for: .milliseconds(20))
        await model.checkForUpdate()
        await first.value
        let checkCalls = await service.checkCallCount()
        XCTAssertEqual(checkCalls, 1)

        await service.setCheckError(.invalidSignature)
        await model.checkForUpdate()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.phase, .idle)
    }

    private func makeResolved(version: String, provenance: EngineProvenance) -> ResolvedEngine {
        ResolvedEngine(
            executableURL: URL(fileURLWithPath: "/tmp/engine-\(version)"),
            version: try! EngineVersion(version),
            upstreamCommit: String(repeating: "a", count: 40),
            provenance: provenance,
            sourceURL: provenance == .bundled ? nil : URL(string: "https://example.invalid/source.tar.gz")
        )
    }
}

private actor ViewModelEngineService: EngineUpdating {
    private var current: ResolvedEngine
    private let installed: ResolvedEngine
    private let checkDelayNanoseconds: UInt64
    private var checkCalls = 0
    private var checkError: EngineUpdateError?

    init(current: ResolvedEngine, installed: ResolvedEngine, checkDelayNanoseconds: UInt64 = 0) {
        self.current = current
        self.installed = installed
        self.checkDelayNanoseconds = checkDelayNanoseconds
    }

    func checkForUpdate() async throws -> EngineUpdateCandidate {
        checkCalls += 1
        if checkDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: checkDelayNanoseconds)
        }
        if let checkError { throw checkError }
        return EngineUpdateCandidate(
            manifest: Self.manifest(version: installed.version),
            rawManifest: Data("manifest".utf8),
            rawSignature: Data("signature".utf8)
        )
    }

    func install(_ candidate: EngineUpdateCandidate) async throws -> ResolvedEngine {
        current = installed
        return installed
    }

    func restoreBundled() async throws -> ResolvedEngine {
        current = ResolvedEngine(
            executableURL: URL(fileURLWithPath: "/tmp/bundled"),
            version: try EngineVersion("1.0.0"),
            upstreamCommit: String(repeating: "a", count: 40),
            provenance: .bundled,
            sourceURL: nil
        )
        return current
    }

    func currentState() -> InstalledEngineState { .bundled }
    func currentEngine() -> ResolvedEngine { current }
    func checkCallCount() -> Int { checkCalls }
    func setCheckError(_ error: EngineUpdateError) { checkError = error }

    private static func manifest(version: EngineVersion) -> EngineManifest {
        EngineManifest(
            schemaVersion: 1,
            engineVersion: version,
            publishedAt: "2026-01-01T00:00:00Z",
            upstreamCommit: String(repeating: "a", count: 40),
            protocolVersions: [1],
            minAppBuild: 1,
            maxAppBuild: 1,
            minMacOS: "14.0",
            architectures: ["arm64", "x86_64"],
            capabilities: ["clean-plan", "apply-plan", "app-list", "uninstall-plan", "tool-plan"],
            archive: EngineAssetDescriptor(
                url: URL(string: "https://example.invalid/engine.tar.gz")!,
                sha256: String(repeating: "b", count: 64),
                byteSize: 1
            ),
            source: EngineAssetDescriptor(
                url: URL(string: "https://example.invalid/source.tar.gz")!,
                sha256: String(repeating: "c", count: 64),
                byteSize: 1
            ),
            files: [
                EngineManifestFile(
                    path: "Mole/bin/gui.sh",
                    sha256: String(repeating: "d", count: 64),
                    byteSize: 1,
                    executable: true
                )
            ]
        )
    }
}
