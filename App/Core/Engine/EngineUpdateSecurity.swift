// SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Darwin
import Foundation

struct EngineManifestVerifier: Sendable {
    let configuration: EngineUpdateConfiguration

    func verifySignedManifest(
        _ rawManifest: Data,
        signature rawSignature: Data,
        baselineVersion: EngineVersion? = nil,
        enforceUpgrade: Bool = true
    ) throws -> EngineManifest {
        try configuration.validateTrustConfiguration()
        guard rawManifest.count <= 8 * 1024 * 1024, rawSignature.count <= 1024 else {
            throw EngineUpdateError.downloadTooLarge
        }
        guard let publicKeyData = configuration.publicKeyData,
              let signatureText = String(data: rawSignature, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let signature = Data(base64Encoded: signatureText), signature.count == 64,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
              publicKey.isValidSignature(signature, for: rawManifest) else {
            throw EngineUpdateError.invalidSignature
        }

        let manifest: EngineManifest
        do {
            manifest = try JSONDecoder().decode(EngineManifest.self, from: rawManifest)
        } catch let error as EngineUpdateError {
            throw error
        } catch {
            throw EngineUpdateError.invalidManifest("JSON decoding failed")
        }
        try manifest.validate()
        try validateCompatibility(manifest)
        if enforceUpgrade, let baselineVersion, manifest.engineVersion <= baselineVersion {
            throw EngineUpdateError.downgradeRejected
        }
        return manifest
    }

    func validateCompatibility(_ manifest: EngineManifest) throws {
        guard configuration.appBuild >= manifest.minAppBuild,
              configuration.appBuild <= manifest.maxAppBuild else {
            throw EngineUpdateError.incompatibleAppBuild
        }
        guard manifest.protocolVersions.contains(BundledMoleBridge.supportedProtocolVersion) else {
            throw EngineUpdateError.incompatibleProtocol
        }
        for capability in EngineUpdateConfiguration.requiredCapabilities.sorted() where !manifest.capabilities.contains(capability) {
            throw EngineUpdateError.missingCapability(capability)
        }
        guard let minimumOS = OperatingSystemVersion(engineString: manifest.minMacOS),
              !Self.isVersion(configuration.currentOS, olderThan: minimumOS) else {
            throw EngineUpdateError.incompatibleOperatingSystem
        }
        guard manifest.architectures.contains(configuration.architecture) else {
            throw EngineUpdateError.incompatibleArchitecture
        }
    }

    func validateHandshake(_ information: EngineInformation, against manifest: EngineManifest) throws {
        guard information.schemaVersion == manifest.schemaVersion,
              information.engineVersion == manifest.engineVersion,
              information.commit == manifest.upstreamCommit,
              information.protocolVersions == manifest.protocolVersions,
              information.minAppBuild == manifest.minAppBuild,
              information.maxAppBuild == manifest.maxAppBuild,
              information.minMacOS == manifest.minMacOS,
              information.architectures == manifest.architectures,
              information.capabilities == manifest.capabilities else {
            throw EngineUpdateError.handshakeFailed("metadata mismatch")
        }
        guard EngineManifest.isTrustedHTTPSURL(information.repository) else {
            throw EngineUpdateError.handshakeFailed("invalid upstream repository")
        }
        try validateCompatibility(manifest)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isVersion(_ lhs: OperatingSystemVersion, olderThan rhs: OperatingSystemVersion) -> Bool {
        if lhs.majorVersion != rhs.majorVersion { return lhs.majorVersion < rhs.majorVersion }
        if lhs.minorVersion != rhs.minorVersion { return lhs.minorVersion < rhs.minorVersion }
        return lhs.patchVersion < rhs.patchVersion
    }
}

protocol EngineUpdateTransport: Sendable {
    func fetch(_ url: URL, maximumBytes: Int) async throws -> Data
}

struct URLSessionEngineUpdateTransport: EngineUpdateTransport {
    func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              response.url?.scheme?.lowercased() == "https" else {
            throw EngineUpdateError.invalidPayload("download failed or redirected outside HTTPS")
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            throw EngineUpdateError.downloadTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 1024 * 1024))
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw EngineUpdateError.downloadTooLarge }
            data.append(byte)
        }
        return data
    }
}

struct EngineProcessResult: Sendable {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data
}

protocol EngineProcessRunning: Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> EngineProcessResult
}

struct SystemEngineProcessRunner: EngineProcessRunning {
    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> EngineProcessResult {
        try await Task.detached(priority: .utility) {
            try Self.runSynchronously(executable: executable, arguments: arguments, timeout: timeout)
        }.value
    }

    private static func runSynchronously(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> EngineProcessResult {
        let process = Process()
        let completion = DispatchSemaphore(value: 0)
        let captureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpruceEngineProcess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: captureDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: captureDirectory) }
        let outputURL = captureDirectory.appendingPathComponent("stdout")
        let errorURL = captureDirectory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer {
            try? output.close()
            try? error.close()
        }
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.standardOutput = output
        process.standardError = error
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "LANG": "C",
            "NO_COLOR": "1"
        ]
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        if completion.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 1)
            }
            throw EngineUpdateError.handshakeFailed("process timed out")
        }
        try output.close()
        try error.close()
        let maximumCapture = 16 * 1024 * 1024
        let outputSize = (try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
        let errorSize = (try FileManager.default.attributesOfItem(atPath: errorURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard outputSize <= maximumCapture, errorSize <= maximumCapture else {
            throw EngineUpdateError.invalidPayload("process output exceeded safety limit")
        }
        return EngineProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: try Data(contentsOf: outputURL),
            standardError: try Data(contentsOf: errorURL)
        )
    }
}

struct EngineHandshake: Sendable {
    let runner: any EngineProcessRunning

    func information(at executableURL: URL) async throws -> EngineInformation {
        let result = try await runner.run(
            executable: executableURL,
            arguments: ["engine-info", "--format", "json"],
            timeout: 8
        )
        guard result.exitCode == 0, result.standardOutput.count <= 256 * 1024 else {
            throw EngineUpdateError.handshakeFailed("engine-info failed")
        }
        do {
            return try JSONDecoder().decode(EngineInformation.self, from: result.standardOutput)
        } catch {
            throw EngineUpdateError.handshakeFailed("invalid engine-info response")
        }
    }
}
