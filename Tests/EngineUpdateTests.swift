// SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation
import XCTest
@testable import SpruceMyMac

final class EngineUpdateTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testSignedManifestValidationAndTampering() throws {
        let fixture = try makeFixture(version: "1.1.0")
        let verifier = EngineManifestVerifier(configuration: fixture.configuration)
        let decoded = try verifier.verifySignedManifest(fixture.manifestData, signature: fixture.signatureData)
        XCTAssertEqual(decoded.engineVersion.description, "1.1.0")

        var tampered = fixture.manifestData
        tampered.append(0x20)
        XCTAssertThrowsError(try verifier.verifySignedManifest(tampered, signature: fixture.signatureData)) {
            XCTAssertEqual($0 as? EngineUpdateError, .invalidSignature)
        }
        var signature = fixture.signatureData
        signature[signature.startIndex] ^= 1
        XCTAssertThrowsError(try verifier.verifySignedManifest(fixture.manifestData, signature: signature)) {
            XCTAssertEqual($0 as? EngineUpdateError, .invalidSignature)
        }
    }

    func testMissingOrMalformedTrustKeyDisablesUpdates() throws {
        let fixture = try makeFixture(version: "1.1.0")
        let disabled = EngineUpdateConfiguration(
            manifestURL: fixture.configuration.manifestURL,
            signatureURL: fixture.configuration.signatureURL,
            signingPublicKeyBase64: "",
            appBuild: fixture.configuration.appBuild,
            currentOS: fixture.configuration.currentOS,
            architecture: fixture.configuration.architecture,
            applicationSupportRoot: fixture.configuration.applicationSupportRoot,
            bundledEngineURL: fixture.configuration.bundledEngineURL
        )
        XCTAssertThrowsError(try disabled.validateTrustConfiguration()) {
            XCTAssertEqual($0 as? EngineUpdateError, .updatesDisabled)
        }
    }

    func testSystemEngineRunnerProvidesRequiredHandshakeEnvironment() async throws {
        let root = makeTemporaryDirectory()
        let bin = root.appendingPathComponent("Mole/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("gui.sh")
        let script = """
        #!/bin/bash
        set -euo pipefail
        [[ -n "$HOME" && -n "$TMPDIR" ]]
        /bin/cat "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/engine-info.json"
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try encoded(try engineInformation(version: "1.0.0"))
            .write(to: bin.deletingLastPathComponent().appendingPathComponent("engine-info.json"))

        let information = try await EngineHandshake(runner: SystemEngineProcessRunner())
            .information(at: executable)
        XCTAssertEqual(information.engineVersion.description, "1.0.0")
    }

    func testManifestRejectsUnsafeAndDuplicateFiles() throws {
        let fixture = try makeFixture(version: "1.1.0")
        for path in [
            "/absolute", "../escape", "Mole/../escape", "Mole//gui.sh",
            "Mole/./gui.sh", "Mole\\gui.sh", "Mole/bin/\0gui.sh", "Mole/bin/\ngui.sh"
        ] {
            XCTAssertFalse(EngineManifest.isSafeRelativePath(path), "accepted unsafe path: \(path)")
        }
        for value in [
            "https://-bad.example/engine.tar.gz",
            "https://user@example.com/engine.tar.gz",
            "https://%00/engine.tar.gz",
            "https://%65xample.com/engine.tar.gz",
            "https://example%2ecom/engine.tar.gz",
            "https://é.com/engine.tar.gz",
            "https://xn--9ca.com/engine.tar.gz",
            "https://example.com:/engine.tar.gz",
            "http://example.com/engine.tar.gz",
            "https://example.com"
        ] {
            XCTAssertFalse(
                EngineManifest.isTrustedHTTPSURL(URL(string: value)!, requiresPath: true),
                "accepted unsafe URL: \(value)"
            )
        }
        XCTAssertTrue(
            EngineManifest.isTrustedHTTPSURL(
                URL(string: "https://github.com/example/engine.tar.gz")!,
                requiresPath: true
            )
        )
        var unsafe = fixture.manifest
        unsafe = replacingFiles(in: unsafe, with: [
            EngineManifestFile(path: "../escape", sha256: String(repeating: "a", count: 64), byteSize: 1, executable: false),
            unsafe.files.last!
        ].sorted { $0.path < $1.path })
        XCTAssertThrowsError(try unsafe.validate())

        let duplicate = replacingFiles(in: fixture.manifest, with: [fixture.manifest.files[0], fixture.manifest.files[0]])
        XCTAssertThrowsError(try duplicate.validate())
    }

    func testCompatibilityAndDowngradeGates() throws {
        let fixture = try makeFixture(version: "1.1.0")
        let verifier = EngineManifestVerifier(configuration: fixture.configuration)
        let baseline = try EngineVersion("1.1.0")
        XCTAssertThrowsError(
            try verifier.verifySignedManifest(
                fixture.manifestData,
                signature: fixture.signatureData,
                baselineVersion: baseline
            )
        ) { XCTAssertEqual($0 as? EngineUpdateError, .downgradeRejected) }

        for (manifest, expected) in [
            (replace(fixture.manifest, minAppBuild: 2), EngineUpdateError.incompatibleAppBuild),
            (replace(fixture.manifest, protocols: [2]), .incompatibleProtocol),
            (replace(fixture.manifest, capabilities: ["clean-plan"]), .missingCapability("app-list")),
            (replace(fixture.manifest, minMacOS: "99.0"), .incompatibleOperatingSystem),
            (replace(fixture.manifest, architectures: ["x86_64"]), .incompatibleArchitecture)
        ] {
            let signed = try sign(manifest, with: fixture.privateKey)
            XCTAssertThrowsError(try verifier.verifySignedManifest(signed.0, signature: signed.1)) {
                XCTAssertEqual($0 as? EngineUpdateError, expected)
            }
        }
    }

    func testPayloadExactHashesExecutableBitsAndSymlinkRejection() throws {
        let fixture = try makeFixture(version: "1.1.0")
        try EnginePayloadVerifier().verify(root: fixture.payloadRoot, manifest: fixture.manifest)

        let launcher = fixture.payloadRoot.appendingPathComponent("Mole/bin/gui.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: launcher.path)
        XCTAssertThrowsError(try EnginePayloadVerifier().verify(root: fixture.payloadRoot, manifest: fixture.manifest))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)

        let link = fixture.payloadRoot.appendingPathComponent("Mole/unsafe-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/tmp"))
        XCTAssertThrowsError(try EnginePayloadVerifier().verify(root: fixture.payloadRoot, manifest: fixture.manifest)) {
            guard case .invalidPayload = $0 as? EngineUpdateError else { return XCTFail("unexpected error: \($0)") }
        }
    }

    func testInstallTransitionsRestoreAndArchiveTampering() async throws {
        let fixture = try makeFixture(version: "1.1.0")
        let transport = MemoryEngineTransport(values: fixture.transportValues)
        let service = EngineUpdateService(
            configuration: fixture.configuration,
            transport: transport,
            runner: FixtureEngineRunner()
        )
        let candidate = try await service.checkForUpdate()
        let installed = try await service.install(candidate)
        XCTAssertEqual(installed.version.description, "1.1.0")
        let installedState = try await service.currentState()
        XCTAssertEqual(
            installedState,
            InstalledEngineState(
                active: try EngineVersion("1.1.0"),
                previous: nil,
                highestAcceptedVersion: try EngineVersion("1.1.0")
            )
        )

        let bundled = try await service.restoreBundled()
        XCTAssertEqual(bundled.provenance, .bundled)
        let restoredState = try await service.currentState()
        XCTAssertEqual(
            restoredState,
            InstalledEngineState(
                active: nil,
                previous: nil,
                highestAcceptedVersion: try EngineVersion("1.1.0")
            )
        )
        do {
            _ = try await service.install(candidate)
            XCTFail("Expected the persisted high-water mark to reject replay after restore")
        } catch let error as EngineUpdateError {
            XCTAssertEqual(error, .downgradeRejected)
        }

        let tamperedFixture = try makeFixture(
            version: "1.2.0",
            root: fixture.configuration.applicationSupportRoot,
            privateKey: fixture.privateKey,
            bundledExecutable: fixture.configuration.bundledEngineURL
        )
        await transport.replace(with: tamperedFixture.transportValues)
        let tamperedCandidate = try await service.checkForUpdate()
        var changed = tamperedFixture.archiveData
        changed.append(0)
        await transport.set(changed, for: tamperedFixture.manifest.archive.url)
        do {
            _ = try await service.install(tamperedCandidate)
            XCTFail("Expected archive tampering to fail")
        } catch let error as EngineUpdateError {
            XCTAssertTrue(
                error == .downloadTooLarge || error == .assetSizeMismatch || error == .assetHashMismatch
            )
        }
    }

    func testHandshakeMismatchFailsBeforeActivation() async throws {
        let fixture = try makeFixture(version: "1.1.0")
        let service = EngineUpdateService(
            configuration: fixture.configuration,
            transport: MemoryEngineTransport(values: fixture.transportValues),
            runner: FixtureEngineRunner(mismatchedExternalVersion: try EngineVersion("9.9.9"))
        )
        let candidate = try await service.checkForUpdate()
        do {
            _ = try await service.install(candidate)
            XCTFail("Expected handshake mismatch")
        } catch let error as EngineUpdateError {
            guard case .handshakeFailed = error else { return XCTFail("unexpected error: \(error)") }
        }
        let state = try await service.currentState()
        XCTAssertEqual(state, .bundled)
    }

    func testConcurrentMutationIsRejectedAndCannotReorderActivation() async throws {
        let root = makeTemporaryDirectory()
        let key = Curve25519.Signing.PrivateKey()
        let slow = try makeFixture(version: "1.2.0", root: root, privateKey: key)
        let fast = try makeFixture(
            version: "1.3.0",
            root: root,
            privateKey: key,
            bundledExecutable: slow.configuration.bundledEngineURL
        )
        let transport = MemoryEngineTransport(values: slow.transportValues)
        await transport.merge(fast.transportValues)
        await transport.setDelay(.milliseconds(200), for: slow.manifest.archive.url)
        let service = EngineUpdateService(
            configuration: slow.configuration,
            transport: transport,
            runner: FixtureEngineRunner()
        )

        let slowTask = Task { try await service.install(slow.candidate) }
        try await Task.sleep(for: .milliseconds(30))
        do {
            _ = try await service.install(fast.candidate)
            XCTFail("Expected overlapping install to fail closed")
        } catch let error as EngineUpdateError {
            XCTAssertEqual(error, .operationInProgress)
        }
        let installed = try await slowTask.value
        XCTAssertEqual(installed.version, try EngineVersion("1.2.0"))
        let state = try await service.currentState()
        XCTAssertEqual(state.active, try EngineVersion("1.2.0"))
        XCTAssertEqual(state.highestAcceptedVersion, try EngineVersion("1.2.0"))
    }

    func testFinalVerificationFailureDoesNotActivate() async throws {
        let fixture = try makeFixture(version: "1.1.0")
        let service = EngineUpdateService(
            configuration: fixture.configuration,
            transport: MemoryEngineTransport(values: fixture.transportValues),
            runner: FixtureEngineRunner(mismatchedFinalVersion: try EngineVersion("9.9.9"))
        )

        do {
            _ = try await service.install(fixture.candidate)
            XCTFail("Expected final-directory verification failure")
        } catch let error as EngineUpdateError {
            guard case .handshakeFailed = error else { return XCTFail("unexpected error: \(error)") }
        }
        let state = try await service.currentState()
        XCTAssertEqual(state, .bundled)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.configuration.applicationSupportRoot
                    .appendingPathComponent("Engines/1.1.0").path
            )
        )
    }

    func testRestoreFailureLeavesDownloadedSelectionUnchanged() async throws {
        let fixture = try makeFixture(version: "1.1.0")
        let runner = FixtureEngineRunner(failBundledAfterCalls: 1)
        let service = EngineUpdateService(
            configuration: fixture.configuration,
            transport: MemoryEngineTransport(values: fixture.transportValues),
            runner: runner
        )
        _ = try await service.install(fixture.candidate)
        let before = try await service.currentState()

        do {
            _ = try await service.restoreBundled()
            XCTFail("Expected bundled verification failure")
        } catch let error as EngineUpdateError {
            guard case .handshakeFailed = error else { return XCTFail("unexpected error: \(error)") }
        }
        let after = try await service.currentState()
        XCTAssertEqual(after, before)
    }

    func testCorruptStateStillFallsBackToBundledEngine() async throws {
        let fixture = try makeFixture(version: "1.1.0")
        let stateURL = fixture.configuration.applicationSupportRoot
            .appendingPathComponent("EngineState.json")
        try Data("not-json".utf8).write(to: stateURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )

        let resolver = EngineResolver(
            configuration: fixture.configuration,
            runner: FixtureEngineRunner()
        )
        let resolved = try await resolver.resolve()

        XCTAssertEqual(resolved.provenance, .bundled)
        XCTAssertEqual(resolved.version, try EngineVersion("1.0.0"))
    }

    func testNewerBundledEngineWinsAfterAppUpdate() async throws {
        let root = makeTemporaryDirectory()
        let key = Curve25519.Signing.PrivateKey()
        let initial = try makeFixture(version: "1.1.0", root: root, privateKey: key)
        let service = EngineUpdateService(
            configuration: initial.configuration,
            transport: MemoryEngineTransport(values: initial.transportValues),
            runner: FixtureEngineRunner()
        )
        _ = try await service.install(initial.candidate)

        let newerBundled = try makeBundledEngine(in: root, information: try engineInformation(version: "1.2.0"))
        let updatedConfiguration = EngineUpdateConfiguration(
            manifestURL: initial.configuration.manifestURL,
            signatureURL: initial.configuration.signatureURL,
            signingPublicKeyBase64: initial.configuration.signingPublicKeyBase64,
            appBuild: initial.configuration.appBuild,
            currentOS: initial.configuration.currentOS,
            architecture: initial.configuration.architecture,
            applicationSupportRoot: root,
            bundledEngineURL: newerBundled
        )
        let resolved = try await EngineResolver(configuration: updatedConfiguration, runner: FixtureEngineRunner()).resolve()
        XCTAssertEqual(resolved.provenance, .bundled)
        XCTAssertEqual(resolved.version, try EngineVersion("1.2.0"))
    }

    func testActiveInvalidFallsBackToPreviousThenBundled() async throws {
        let root = makeTemporaryDirectory()
        let key = Curve25519.Signing.PrivateKey()
        let first = try makeFixture(version: "1.1.0", root: root, privateKey: key)
        let transport = MemoryEngineTransport(values: first.transportValues)
        let service = EngineUpdateService(
            configuration: first.configuration,
            transport: transport,
            runner: FixtureEngineRunner()
        )
        _ = try await service.install(try await service.checkForUpdate())

        let second = try makeFixture(version: "1.2.0", root: root, privateKey: key, bundledExecutable: first.configuration.bundledEngineURL)
        await transport.replace(with: second.transportValues)
        let secondCandidate = try await service.checkForUpdate()
        _ = try await service.install(secondCandidate)
        let transitionedState = try await service.currentState()
        XCTAssertEqual(
            transitionedState,
            InstalledEngineState(
                active: try EngineVersion("1.2.0"),
                previous: try EngineVersion("1.1.0"),
                highestAcceptedVersion: try EngineVersion("1.2.0")
            )
        )

        let activeLauncher = root.appendingPathComponent("Engines/1.2.0/Mole/bin/gui.sh")
        try Data("tampered".utf8).write(to: activeLauncher)
        let fallback = try await service.currentEngine()
        XCTAssertEqual(fallback.version.description, "1.1.0")
        XCTAssertEqual(fallback.provenance, .previous)

        let third = try makeFixture(
            version: "1.3.0",
            root: root,
            privateKey: key,
            bundledExecutable: first.configuration.bundledEngineURL
        )
        await transport.replace(with: third.transportValues)
        _ = try await service.install(try await service.checkForUpdate())
        let recoveredState = try await service.currentState()
        XCTAssertEqual(recoveredState.previous, try EngineVersion("1.1.0"))
        XCTAssertEqual(recoveredState.highestAcceptedVersion, try EngineVersion("1.3.0"))

        let thirdLauncher = root.appendingPathComponent("Engines/1.3.0/Mole/bin/gui.sh")
        try Data("tampered".utf8).write(to: thirdLauncher)
        let secondFallback = try await service.currentEngine()
        XCTAssertEqual(secondFallback.version.description, "1.1.0")
        XCTAssertEqual(secondFallback.provenance, .previous)

        let previousLauncher = root.appendingPathComponent("Engines/1.1.0/Mole/bin/gui.sh")
        try Data("tampered".utf8).write(to: previousLauncher)
        let bundled = try await service.currentEngine()
        XCTAssertEqual(bundled.provenance, .bundled)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let configuration: EngineUpdateConfiguration
        let privateKey: Curve25519.Signing.PrivateKey
        let manifest: EngineManifest
        let manifestData: Data
        let signatureData: Data
        let archiveData: Data
        let payloadRoot: URL

        var candidate: EngineUpdateCandidate {
            EngineUpdateCandidate(manifest: manifest, rawManifest: manifestData, rawSignature: signatureData)
        }

        var transportValues: [URL: Data] {
            [
                configuration.manifestURL: manifestData,
                configuration.signatureURL: signatureData,
                manifest.archive.url: archiveData
            ]
        }
    }

    private func makeFixture(
        version: String,
        root: URL? = nil,
        privateKey: Curve25519.Signing.PrivateKey = .init(),
        bundledExecutable: URL? = nil
    ) throws -> Fixture {
        let supportRoot = root ?? makeTemporaryDirectory()
        let workspace = makeTemporaryDirectory()
        let payload = workspace.appendingPathComponent("payload", isDirectory: true)
        let bin = payload.appendingPathComponent("Mole/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let launcher = bin.appendingPathComponent("gui.sh")
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let infoURL = payload.appendingPathComponent("Mole/engine-info.json")
        let information = try engineInformation(version: version)
        try encoded(information).write(to: infoURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: infoURL.path)
        let upstream = payload.appendingPathComponent("UPSTREAM.json")
        try Data("{}\n".utf8).write(to: upstream)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: upstream.path)

        let archive = workspace.appendingPathComponent("engine.tar.gz")
        try runTar(arguments: ["-czf", archive.path, "-C", payload.path, "Mole", "UPSTREAM.json"])
        let archiveData = try Data(contentsOf: archive)
        let files = try regularFiles(in: payload)
        let engineVersion = try EngineVersion(version)
        let manifest = EngineManifest(
            schemaVersion: 1,
            engineVersion: engineVersion,
            publishedAt: "2026-01-01T00:00:00Z",
            upstreamCommit: String(repeating: "a", count: 40),
            protocolVersions: [1],
            minAppBuild: 1,
            maxAppBuild: 1,
            minMacOS: "14.0",
            architectures: ["arm64", "x86_64"],
            capabilities: ["clean-plan", "apply-plan", "app-list", "uninstall-plan", "tool-plan"],
            archive: EngineAssetDescriptor(
                url: URL(string: "https://example.invalid/engine-\(version).tar.gz")!,
                sha256: EngineManifestVerifier.sha256(archiveData),
                byteSize: archiveData.count
            ),
            source: EngineAssetDescriptor(
                url: URL(string: "https://example.invalid/engine-\(version)-source.tar.gz")!,
                sha256: String(repeating: "b", count: 64),
                byteSize: 1
            ),
            files: files
        )
        let (manifestData, signatureData) = try sign(manifest, with: privateKey)

        let bundled = try bundledExecutable ?? makeBundledEngine(in: supportRoot, information: try engineInformation(version: "1.0.0"))
        let configuration = EngineUpdateConfiguration(
            manifestURL: URL(string: "https://example.invalid/engine-manifest.json")!,
            signatureURL: URL(string: "https://example.invalid/engine-manifest.sig")!,
            signingPublicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            appBuild: 1,
            currentOS: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0),
            architecture: "arm64",
            applicationSupportRoot: supportRoot,
            bundledEngineURL: bundled
        )
        return Fixture(
            configuration: configuration,
            privateKey: privateKey,
            manifest: manifest,
            manifestData: manifestData,
            signatureData: signatureData,
            archiveData: archiveData,
            payloadRoot: payload
        )
    }

    private func makeBundledEngine(in root: URL, information: EngineInformation) throws -> URL {
        let bin = root.appendingPathComponent("Bundled/Mole/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("gui.sh")
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try encoded(information).write(to: bin.deletingLastPathComponent().appendingPathComponent("engine-info.json"))
        return executable
    }

    private func engineInformation(version: String) throws -> EngineInformation {
        EngineInformation(
            schemaVersion: 1,
            engineVersion: try EngineVersion(version),
            repository: URL(string: "https://github.com/tw93/Mole.git")!,
            commit: String(repeating: "a", count: 40),
            checkedAt: "2026-01-01",
            license: "GPL-3.0",
            protocolVersions: [1],
            minAppBuild: 1,
            maxAppBuild: 1,
            minMacOS: "14.0",
            architectures: ["arm64", "x86_64"],
            capabilities: ["clean-plan", "apply-plan", "app-list", "uninstall-plan", "tool-plan"]
        )
    }

    private func regularFiles(in root: URL) throws -> [EngineManifestFile] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        var files: [EngineManifestFile] = []
        while let url = enumerator.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let relative = url.standardizedFileURL.pathComponents
                .dropFirst(root.standardizedFileURL.pathComponents.count)
                .joined(separator: "/")
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            files.append(EngineManifestFile(
                path: relative,
                sha256: try EngineManifestVerifier.sha256(fileAt: url),
                byteSize: (attributes[.size] as! NSNumber).intValue,
                executable: (mode & 0o111) != 0
            ))
        }
        return files.sorted { $0.path < $1.path }
    }

    private func sign(_ manifest: EngineManifest, with key: Curve25519.Signing.PrivateKey) throws -> (Data, Data) {
        let data = try encoded(manifest)
        let signature = try key.signature(for: data).base64EncodedString() + "\n"
        return (data, Data(signature.utf8))
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func runTar(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpruceEngineUpdateTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func replacingFiles(in manifest: EngineManifest, with files: [EngineManifestFile]) -> EngineManifest {
        EngineManifest(
            schemaVersion: manifest.schemaVersion, engineVersion: manifest.engineVersion,
            publishedAt: manifest.publishedAt, upstreamCommit: manifest.upstreamCommit,
            protocolVersions: manifest.protocolVersions, minAppBuild: manifest.minAppBuild,
            maxAppBuild: manifest.maxAppBuild, minMacOS: manifest.minMacOS,
            architectures: manifest.architectures, capabilities: manifest.capabilities,
            archive: manifest.archive, source: manifest.source, files: files
        )
    }

    private func replace(
        _ manifest: EngineManifest,
        minAppBuild: Int? = nil,
        protocols: [Int]? = nil,
        capabilities: [String]? = nil,
        minMacOS: String? = nil,
        architectures: [String]? = nil
    ) -> EngineManifest {
        EngineManifest(
            schemaVersion: manifest.schemaVersion, engineVersion: manifest.engineVersion,
            publishedAt: manifest.publishedAt, upstreamCommit: manifest.upstreamCommit,
            protocolVersions: protocols ?? manifest.protocolVersions,
            minAppBuild: minAppBuild ?? manifest.minAppBuild,
            maxAppBuild: max(minAppBuild ?? manifest.minAppBuild, manifest.maxAppBuild),
            minMacOS: minMacOS ?? manifest.minMacOS,
            architectures: architectures ?? manifest.architectures,
            capabilities: capabilities ?? manifest.capabilities,
            archive: manifest.archive, source: manifest.source, files: manifest.files
        )
    }
}

private actor MemoryEngineTransport: EngineUpdateTransport {
    private var values: [URL: Data]
    private var delays: [URL: Duration] = [:]

    init(values: [URL: Data]) { self.values = values }

    func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        if let delay = delays[url] { try await Task.sleep(for: delay) }
        guard let data = values[url] else { throw EngineUpdateError.invalidPayload("missing fixture URL") }
        guard data.count <= maximumBytes else { throw EngineUpdateError.downloadTooLarge }
        return data
    }

    func set(_ data: Data, for url: URL) { values[url] = data }
    func replace(with values: [URL: Data]) { self.values = values }
    func merge(_ values: [URL: Data]) { self.values.merge(values) { _, new in new } }
    func setDelay(_ delay: Duration, for url: URL) { delays[url] = delay }
}

private actor FixtureEngineRunner: EngineProcessRunning {
    let mismatchedExternalVersion: EngineVersion?
    let mismatchedFinalVersion: EngineVersion?
    let failBundledAfterCalls: Int?
    private var bundledCalls = 0

    init(
        mismatchedExternalVersion: EngineVersion? = nil,
        mismatchedFinalVersion: EngineVersion? = nil,
        failBundledAfterCalls: Int? = nil
    ) {
        self.mismatchedExternalVersion = mismatchedExternalVersion
        self.mismatchedFinalVersion = mismatchedFinalVersion
        self.failBundledAfterCalls = failBundledAfterCalls
    }

    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> EngineProcessResult {
        if executable.path == "/usr/bin/tar" {
            return try await SystemEngineProcessRunner().run(executable: executable, arguments: arguments, timeout: timeout)
        }
        if executable.path.contains("/Bundled/") {
            bundledCalls += 1
            if let failBundledAfterCalls, bundledCalls > failBundledAfterCalls {
                throw EngineUpdateError.handshakeFailed("bundled fixture failure")
            }
        }
        let informationURL = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("engine-info.json")
        var information = try JSONDecoder().decode(EngineInformation.self, from: Data(contentsOf: informationURL))
        let replacementVersion: EngineVersion?
        if executable.path.contains("EngineDownloads") {
            replacementVersion = mismatchedExternalVersion
        } else if executable.path.contains("/Engines/") {
            replacementVersion = mismatchedFinalVersion
        } else {
            replacementVersion = nil
        }
        if let replacementVersion {
            information = EngineInformation(
                schemaVersion: information.schemaVersion, engineVersion: replacementVersion,
                repository: information.repository, commit: information.commit, checkedAt: information.checkedAt,
                license: information.license, protocolVersions: information.protocolVersions,
                minAppBuild: information.minAppBuild, maxAppBuild: information.maxAppBuild,
                minMacOS: information.minMacOS, architectures: information.architectures,
                capabilities: information.capabilities
            )
        }
        return EngineProcessResult(exitCode: 0, standardOutput: try JSONEncoder().encode(information), standardError: Data())
    }
}
