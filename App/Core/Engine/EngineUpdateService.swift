// SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Darwin
import Foundation

private enum EngineInstallLayout {
    static let manifestName = "manifest.json"
    static let signatureName = "manifest.sig"
    static let launcherPath = "Mole/bin/gui.sh"
}

actor EngineStateStore {
    private let root: URL
    private let fileManager = FileManager.default
    private let maximumStateBytes = 64 * 1024

    init(root: URL) { self.root = root }

    var enginesDirectory: URL { root.appendingPathComponent("Engines", isDirectory: true) }
    var downloadsDirectory: URL { root.appendingPathComponent("EngineDownloads", isDirectory: true) }
    private var stateURL: URL { root.appendingPathComponent("EngineState.json") }

    func prepareDirectories() throws {
        try ensurePrivateDirectory(root)
        try ensurePrivateDirectory(enginesDirectory)
        try ensurePrivateDirectory(downloadsDirectory)
    }

    func load() throws -> InstalledEngineState {
        try prepareDirectories()
        guard fileManager.fileExists(atPath: stateURL.path) else { return .bundled }
        var info = stat()
        guard lstat(stateURL.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              (info.st_mode & 0o022) == 0,
              info.st_size >= 0,
              info.st_size <= maximumStateBytes else {
            throw EngineUpdateError.stateCorrupt
        }
        do {
            return try JSONDecoder().decode(
                InstalledEngineState.self,
                from: Data(contentsOf: stateURL, options: [.mappedIfSafe])
            )
        } catch {
            throw EngineUpdateError.stateCorrupt
        }
    }

    func activate(_ version: EngineVersion, verifiedPrevious: EngineVersion?) throws -> InstalledEngineState {
        var state = try load()
        if let highest = state.highestAcceptedVersion, version <= highest {
            throw EngineUpdateError.downgradeRejected
        }
        state.active = version
        state.previous = verifiedPrevious == version ? nil : verifiedPrevious
        state.highestAcceptedVersion = max(state.highestAcceptedVersion ?? version, version)
        try write(state)
        return state
    }

    func restoreBundled() throws {
        var state = try load()
        state.active = nil
        state.previous = nil
        try write(state)
    }

    func installDirectory(for version: EngineVersion) -> URL {
        enginesDirectory.appendingPathComponent(version.description, isDirectory: true)
    }

    func makeStagingDirectory() throws -> URL {
        try prepareDirectories()
        let url = downloadsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    private func write(_ state: InstalledEngineState) throws {
        try prepareDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= maximumStateBytes else { throw EngineUpdateError.stateCorrupt }

        let temporaryURL = root.appendingPathComponent(".EngineState.\(UUID().uuidString).tmp")
        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw EngineUpdateError.stateCorrupt }
        var descriptorOpen = true
        var committed = false
        defer {
            if descriptorOpen { close(descriptor) }
            if !committed { try? fileManager.removeItem(at: temporaryURL) }
        }
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    buffer.count - written
                )
                guard count > 0 else { throw EngineUpdateError.stateCorrupt }
                written += count
            }
        }
        guard fsync(descriptor) == 0, close(descriptor) == 0 else {
            throw EngineUpdateError.stateCorrupt
        }
        descriptorOpen = false
        guard rename(temporaryURL.path, stateURL.path) == 0 else {
            throw EngineUpdateError.stateCorrupt
        }
        committed = true
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            var info = stat()
            guard lstat(url.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == getuid() else {
                throw EngineUpdateError.invalidPayload("unsafe engine data directory")
            }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        var secured = stat()
        guard lstat(url.path, &secured) == 0,
              (secured.st_mode & S_IFMT) == S_IFDIR,
              secured.st_uid == getuid(),
              (secured.st_mode & 0o077) == 0 else {
            throw EngineUpdateError.invalidPayload("insecure engine data directory permissions")
        }
    }
}

struct EnginePayloadVerifier: Sendable {
    func verify(root: URL, manifest: EngineManifest) throws {
        let fileManager = FileManager.default
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              rootInfo.st_uid == getuid(),
              (rootInfo.st_mode & 0o022) == 0 else {
            throw EngineUpdateError.invalidPayload("unsafe payload root")
        }
        let expected = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
        var actualPaths = Set<String>()
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw EngineUpdateError.invalidPayload("cannot enumerate payload")
        }

        while let item = enumerator.nextObject() as? URL {
            let rootComponents = root.standardizedFileURL.pathComponents
            let itemComponents = item.standardizedFileURL.pathComponents
            guard itemComponents.starts(with: rootComponents), itemComponents.count > rootComponents.count else {
                throw EngineUpdateError.invalidPayload("path escaped payload")
            }
            let relative = itemComponents.dropFirst(rootComponents.count).joined(separator: "/")
            guard EngineManifest.isSafeRelativePath(relative) else {
                throw EngineUpdateError.unsafeArchive(relative)
            }
            var info = stat()
            guard lstat(item.path, &info) == 0 else {
                throw EngineUpdateError.invalidPayload("cannot inspect \(relative)")
            }
            let kind = info.st_mode & S_IFMT
            guard info.st_uid == getuid(), (info.st_mode & 0o022) == 0 else {
                throw EngineUpdateError.invalidPayload("unsafe ownership or permissions: \(relative)")
            }
            if kind == S_IFDIR { continue }
            guard kind == S_IFREG else {
                throw EngineUpdateError.invalidPayload("symlink or special file: \(relative)")
            }
            guard info.st_nlink == 1 else {
                throw EngineUpdateError.invalidPayload("hard link: \(relative)")
            }
            if relative == EngineInstallLayout.manifestName || relative == EngineInstallLayout.signatureName {
                continue
            }
            guard let file = expected[relative], actualPaths.insert(relative).inserted else {
                throw EngineUpdateError.invalidPayload("unexpected file: \(relative)")
            }
            guard info.st_size == file.byteSize else {
                throw EngineUpdateError.invalidPayload("size mismatch: \(relative)")
            }
            let isExecutable = (info.st_mode & 0o111) != 0
            guard isExecutable == file.executable else {
                throw EngineUpdateError.invalidPayload("executable bit mismatch: \(relative)")
            }
            guard try EngineManifestVerifier.sha256(fileAt: item) == file.sha256 else {
                throw EngineUpdateError.invalidPayload("hash mismatch: \(relative)")
            }
        }
        guard actualPaths == Set(expected.keys) else {
            throw EngineUpdateError.invalidPayload("payload file set mismatch")
        }
        let launcher = root.appendingPathComponent(EngineInstallLayout.launcherPath)
        guard fileManager.isExecutableFile(atPath: launcher.path) else {
            throw EngineUpdateError.invalidPayload("engine launcher is not executable")
        }
    }
}

struct InstalledEngineVerifier: Sendable {
    let configuration: EngineUpdateConfiguration
    let runner: any EngineProcessRunning

    func verify(version: EngineVersion, directory: URL, provenance: EngineProvenance) async throws -> ResolvedEngine {
        let manifestURL = directory.appendingPathComponent(EngineInstallLayout.manifestName)
        let signatureURL = directory.appendingPathComponent(EngineInstallLayout.signatureName)
        let rawManifest = try boundedData(at: manifestURL, maximumBytes: 8 * 1024 * 1024)
        let rawSignature = try boundedData(at: signatureURL, maximumBytes: 1024)
        let verifier = EngineManifestVerifier(configuration: configuration)
        let manifest = try verifier.verifySignedManifest(
            rawManifest,
            signature: rawSignature,
            baselineVersion: nil,
            enforceUpgrade: false
        )
        guard manifest.engineVersion == version else {
            throw EngineUpdateError.invalidPayload("installed version mismatch")
        }
        try EnginePayloadVerifier().verify(root: directory, manifest: manifest)
        let executable = directory.appendingPathComponent(EngineInstallLayout.launcherPath)
        let information = try await EngineHandshake(runner: runner).information(at: executable)
        try verifier.validateHandshake(information, against: manifest)
        return ResolvedEngine(
            executableURL: executable,
            version: version,
            upstreamCommit: manifest.upstreamCommit,
            provenance: provenance,
            sourceURL: manifest.source.url
        )
    }

    private func boundedData(at url: URL, maximumBytes: Int) throws -> Data {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, (info.st_mode & 0o022) == 0,
              info.st_size >= 0, info.st_size <= maximumBytes else {
            throw EngineUpdateError.downloadTooLarge
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }
}

protocol EngineResolving: Sendable {
    func resolve() async throws -> ResolvedEngine
}

actor EngineResolver: EngineResolving {
    private let configuration: EngineUpdateConfiguration
    private let runner: any EngineProcessRunning
    private let store: EngineStateStore

    init(configuration: EngineUpdateConfiguration, runner: any EngineProcessRunning = SystemEngineProcessRunner()) {
        self.configuration = configuration
        self.runner = runner
        self.store = EngineStateStore(root: configuration.applicationSupportRoot)
    }

    func resolve() async throws -> ResolvedEngine {
        let bundled = try? await resolveBundledEngine()
        guard let state = try? await store.load() else {
            if let bundled { return bundled }
            throw EngineUpdateError.noEngineAvailable
        }
        var external: ResolvedEngine?
        if configuration.publicKeyData != nil, state.active != nil || state.previous != nil {
            let verifier = InstalledEngineVerifier(configuration: configuration, runner: runner)
            if let active = state.active {
                external = try? await verifier.verify(
                    version: active,
                    directory: await store.installDirectory(for: active),
                    provenance: .downloaded
                )
            }
            if external == nil, let previous = state.previous {
                external = try? await verifier.verify(
                    version: previous,
                    directory: await store.installDirectory(for: previous),
                    provenance: .previous
                )
            }
        }
        if let external {
            if let bundled, bundled.version > external.version { return bundled }
            return external
        }
        if let bundled { return bundled }
        throw EngineUpdateError.noEngineAvailable
    }

    func state() async throws -> InstalledEngineState { try await store.load() }

    func resolveBundledEngine() async throws -> ResolvedEngine {
        guard FileManager.default.isExecutableFile(atPath: configuration.bundledEngineURL.path) else {
            throw EngineUpdateError.noEngineAvailable
        }
        let information = try await EngineHandshake(runner: runner).information(at: configuration.bundledEngineURL)
        guard information.schemaVersion == 1,
              information.protocolVersions.contains(BundledMoleBridge.supportedProtocolVersion),
              configuration.appBuild >= information.minAppBuild,
              configuration.appBuild <= information.maxAppBuild,
              information.architectures.contains(configuration.architecture),
              EngineUpdateConfiguration.requiredCapabilities.isSubset(of: Set(information.capabilities)),
              let minimumOS = OperatingSystemVersion(engineString: information.minMacOS),
              !Self.isOlder(configuration.currentOS, than: minimumOS) else {
            throw EngineUpdateError.noEngineAvailable
        }
        return ResolvedEngine(
            executableURL: configuration.bundledEngineURL,
            version: information.engineVersion,
            upstreamCommit: information.commit,
            provenance: .bundled,
            sourceURL: nil
        )
    }

    private static func isOlder(_ lhs: OperatingSystemVersion, than rhs: OperatingSystemVersion) -> Bool {
        if lhs.majorVersion != rhs.majorVersion { return lhs.majorVersion < rhs.majorVersion }
        if lhs.minorVersion != rhs.minorVersion { return lhs.minorVersion < rhs.minorVersion }
        return lhs.patchVersion < rhs.patchVersion
    }
}

protocol EngineUpdating: Sendable {
    func checkForUpdate() async throws -> EngineUpdateCandidate
    func install(_ candidate: EngineUpdateCandidate) async throws -> ResolvedEngine
    func restoreBundled() async throws -> ResolvedEngine
    func currentState() async throws -> InstalledEngineState
    func currentEngine() async throws -> ResolvedEngine
}

actor EngineUpdateService: EngineUpdating {
    private let configuration: EngineUpdateConfiguration
    private let transport: any EngineUpdateTransport
    private let runner: any EngineProcessRunning
    private let store: EngineStateStore
    private let resolver: EngineResolver
    private let fileManager = FileManager.default
    private var mutationInProgress = false

    init(
        configuration: EngineUpdateConfiguration,
        transport: any EngineUpdateTransport = URLSessionEngineUpdateTransport(),
        runner: any EngineProcessRunning = SystemEngineProcessRunner(),
        resolver: EngineResolver? = nil
    ) {
        self.configuration = configuration
        self.transport = transport
        self.runner = runner
        self.store = EngineStateStore(root: configuration.applicationSupportRoot)
        self.resolver = resolver ?? EngineResolver(configuration: configuration, runner: runner)
    }

    func checkForUpdate() async throws -> EngineUpdateCandidate {
        try configuration.validateTrustConfiguration()
        async let manifestDownload = transport.fetch(configuration.manifestURL, maximumBytes: 8 * 1024 * 1024)
        async let signatureDownload = transport.fetch(configuration.signatureURL, maximumBytes: 1024)
        let (rawManifest, rawSignature) = try await (manifestDownload, signatureDownload)
        let baseline = try await baselineVersion()
        let manifest = try EngineManifestVerifier(configuration: configuration).verifySignedManifest(
            rawManifest,
            signature: rawSignature,
            baselineVersion: baseline,
            enforceUpgrade: true
        )
        return EngineUpdateCandidate(manifest: manifest, rawManifest: rawManifest, rawSignature: rawSignature)
    }

    func install(_ candidate: EngineUpdateCandidate) async throws -> ResolvedEngine {
        try beginMutation()
        defer { endMutation() }
        try configuration.validateTrustConfiguration()

        let verifiedBaseline = try await resolver.resolve()
        let baseline = try await baselineVersion(resolved: verifiedBaseline)
        let verifier = EngineManifestVerifier(configuration: configuration)
        let manifest = try verifier.verifySignedManifest(
            candidate.rawManifest,
            signature: candidate.rawSignature,
            baselineVersion: baseline,
            enforceUpgrade: true
        )
        guard manifest == candidate.manifest else {
            throw EngineUpdateError.invalidManifest("candidate changed")
        }
        let archiveData = try await transport.fetch(
            manifest.archive.url,
            maximumBytes: min(manifest.archive.byteSize, EngineManifest.maximumArchiveBytes)
        )
        guard archiveData.count == manifest.archive.byteSize else { throw EngineUpdateError.assetSizeMismatch }
        guard EngineManifestVerifier.sha256(archiveData) == manifest.archive.sha256 else {
            throw EngineUpdateError.assetHashMismatch
        }

        let staging = try await store.makeStagingDirectory()
        defer { try? fileManager.removeItem(at: staging) }
        let archiveURL = staging.appendingPathComponent("engine.tar.gz")
        try archiveData.write(to: archiveURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archiveURL.path)
        try await validateArchiveList(archiveURL, manifest: manifest)

        let payload = staging.appendingPathComponent("payload", isDirectory: true)
        try fileManager.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let extraction = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archiveURL.path, "-C", payload.path],
            timeout: 30
        )
        guard extraction.exitCode == 0 else { throw EngineUpdateError.invalidPayload("archive extraction failed") }
        try EnginePayloadVerifier().verify(root: payload, manifest: manifest)
        let executable = payload.appendingPathComponent(EngineInstallLayout.launcherPath)
        let information = try await EngineHandshake(runner: runner).information(at: executable)
        try verifier.validateHandshake(information, against: manifest)

        try candidate.rawManifest.write(to: payload.appendingPathComponent(EngineInstallLayout.manifestName), options: .atomic)
        try candidate.rawSignature.write(to: payload.appendingPathComponent(EngineInstallLayout.signatureName), options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payload.appendingPathComponent(EngineInstallLayout.manifestName).path)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payload.appendingPathComponent(EngineInstallLayout.signatureName).path)

        let finalDirectory = await store.installDirectory(for: manifest.engineVersion)
        var finalDirectoryShouldBeRemoved = false
        do {
            if fileManager.fileExists(atPath: finalDirectory.path) {
                let storedManifest = try Data(
                    contentsOf: finalDirectory.appendingPathComponent(EngineInstallLayout.manifestName),
                    options: [.mappedIfSafe]
                )
                let storedSignature = try Data(
                    contentsOf: finalDirectory.appendingPathComponent(EngineInstallLayout.signatureName),
                    options: [.mappedIfSafe]
                )
                guard storedManifest == candidate.rawManifest, storedSignature == candidate.rawSignature else {
                    throw EngineUpdateError.invalidPayload("version already exists with different signed contents")
                }
                finalDirectoryShouldBeRemoved = true
            } else {
                try fileManager.moveItem(at: payload, to: finalDirectory)
                finalDirectoryShouldBeRemoved = true
            }

            let installed = try await InstalledEngineVerifier(configuration: configuration, runner: runner).verify(
                version: manifest.engineVersion,
                directory: finalDirectory,
                provenance: .downloaded
            )
            let previous = verifiedBaseline.provenance == .bundled ? nil : verifiedBaseline.version
            _ = try await store.activate(manifest.engineVersion, verifiedPrevious: previous)
            finalDirectoryShouldBeRemoved = false
            return installed
        } catch {
            if finalDirectoryShouldBeRemoved {
                try? fileManager.removeItem(at: finalDirectory)
            }
            throw error
        }
    }

    func restoreBundled() async throws -> ResolvedEngine {
        try beginMutation()
        defer { endMutation() }
        let bundled = try await resolver.resolveBundledEngine()
        try await store.restoreBundled()
        return bundled
    }

    func currentState() async throws -> InstalledEngineState { try await store.load() }
    func currentEngine() async throws -> ResolvedEngine { try await resolver.resolve() }

    private func beginMutation() throws {
        guard !mutationInProgress else { throw EngineUpdateError.operationInProgress }
        mutationInProgress = true
    }

    private func endMutation() {
        mutationInProgress = false
    }

    private func baselineVersion(resolved: ResolvedEngine? = nil) async throws -> EngineVersion {
        let state = try await store.load()
        let resolvedVersion: EngineVersion
        if let resolved {
            resolvedVersion = resolved.version
        } else {
            resolvedVersion = try await resolver.resolve().version
        }
        return max(state.highestAcceptedVersion ?? resolvedVersion, resolvedVersion)
    }

    private func validateArchiveList(_ archiveURL: URL, manifest: EngineManifest) async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-tzf", archiveURL.path],
            timeout: 15
        )
        guard result.exitCode == 0, result.standardOutput.count <= 8 * 1024 * 1024,
              let listing = String(data: result.standardOutput, encoding: .utf8) else {
            throw EngineUpdateError.invalidPayload("cannot list archive")
        }
        let expectedFiles = Set(manifest.files.map(\.path))
        var allowedDirectories = Set<String>()
        for file in expectedFiles {
            var components = file.split(separator: "/").map(String.init)
            _ = components.popLast()
            while !components.isEmpty {
                allowedDirectories.insert(components.joined(separator: "/"))
                _ = components.popLast()
            }
        }
        var seen = Set<String>()
        for rawLine in listing.split(separator: "\n", omittingEmptySubsequences: false) {
            var path = String(rawLine)
            if path.isEmpty { continue }
            let wasDirectory = path.hasSuffix("/")
            if wasDirectory { path.removeLast() }
            guard EngineManifest.isSafeRelativePath(path), seen.insert(path + (wasDirectory ? "/" : "")).inserted else {
                throw EngineUpdateError.unsafeArchive(path)
            }
            if wasDirectory {
                guard allowedDirectories.contains(path) else { throw EngineUpdateError.unsafeArchive(path) }
            } else {
                guard expectedFiles.contains(path) else { throw EngineUpdateError.unsafeArchive(path) }
            }
        }
        guard expectedFiles.isSubset(of: Set(seen.compactMap { $0.hasSuffix("/") ? nil : $0 })) else {
            throw EngineUpdateError.invalidPayload("archive file set mismatch")
        }
    }
}
