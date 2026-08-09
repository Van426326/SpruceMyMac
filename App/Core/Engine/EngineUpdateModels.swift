// SPDX-License-Identifier: GPL-3.0-only

import Foundation

struct EngineVersion: Codable, Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ value: String) throws {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0,
              String(major) == parts[0], String(minor) == parts[1], String(patch) == parts[2] else {
            throw EngineUpdateError.invalidManifest("invalid engine version")
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

struct EngineAssetDescriptor: Codable, Equatable, Sendable {
    let url: URL
    let sha256: String
    let byteSize: Int
}

struct EngineManifestFile: Codable, Equatable, Sendable {
    let path: String
    let sha256: String
    let byteSize: Int
    let executable: Bool
}

struct EngineManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let engineVersion: EngineVersion
    let publishedAt: String
    let upstreamCommit: String
    let protocolVersions: [Int]
    let minAppBuild: Int
    let maxAppBuild: Int
    let minMacOS: String
    let architectures: [String]
    let capabilities: [String]
    let archive: EngineAssetDescriptor
    let source: EngineAssetDescriptor
    let files: [EngineManifestFile]

    static let maximumArchiveBytes = 256 * 1024 * 1024
    static let maximumSourceBytes = 2 * 1024 * 1024 * 1024
    static let maximumFileBytes = 128 * 1024 * 1024
    static let maximumFileCount = 20_000

    func validate() throws {
        guard schemaVersion == 1 else { throw EngineUpdateError.unsupportedSchema(schemaVersion) }
        guard Self.isCommit(upstreamCommit), minAppBuild > 0, maxAppBuild >= minAppBuild,
              Self.isCanonicalTimestamp(publishedAt) else {
            throw EngineUpdateError.invalidManifest("invalid commit, publication time, or app build range")
        }
        guard Self.isUnique(protocolVersions), !protocolVersions.isEmpty,
              protocolVersions.allSatisfy({ $0 > 0 }) else {
            throw EngineUpdateError.invalidManifest("invalid protocol versions")
        }
        guard Self.isUnique(architectures), !architectures.isEmpty,
              architectures.allSatisfy({ $0 == "arm64" || $0 == "x86_64" }) else {
            throw EngineUpdateError.invalidManifest("invalid architectures")
        }
        guard Self.isUnique(capabilities), !capabilities.isEmpty,
              capabilities.allSatisfy({ Self.isIdentifier($0) }) else {
            throw EngineUpdateError.invalidManifest("invalid capabilities")
        }
        guard OperatingSystemVersion(engineString: minMacOS) != nil else {
            throw EngineUpdateError.invalidManifest("invalid minimum macOS")
        }
        try Self.validate(asset: archive, maximumBytes: Self.maximumArchiveBytes)
        try Self.validate(asset: source, maximumBytes: Self.maximumSourceBytes)
        guard !files.isEmpty, files.count <= Self.maximumFileCount else {
            throw EngineUpdateError.invalidManifest("invalid file count")
        }
        let paths = files.map(\.path)
        guard Self.isUnique(paths), paths == paths.sorted() else {
            throw EngineUpdateError.invalidManifest("duplicate or unsorted files")
        }
        var total = 0
        for file in files {
            guard Self.isSafeRelativePath(file.path), Self.isHash(file.sha256),
                  file.byteSize >= 0, file.byteSize <= Self.maximumFileBytes else {
                throw EngineUpdateError.invalidManifest("invalid file entry")
            }
            let (next, overflow) = total.addingReportingOverflow(file.byteSize)
            guard !overflow, next <= Self.maximumSourceBytes else {
                throw EngineUpdateError.invalidManifest("unreasonable payload size")
            }
            total = next
        }
        guard paths.contains("Mole/bin/gui.sh") else {
            throw EngineUpdateError.invalidManifest("engine launcher missing")
        }
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func isHash(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }

    static func isTrustedHTTPSURL(_ url: URL, requiresPath: Bool = false) -> Bool {
        let value = url.absoluteString
        guard value.hasPrefix("https://"), url.user == nil, url.password == nil,
              let host = url.host, !host.isEmpty else {
            return false
        }

        let suffix = value.dropFirst("https://".count)
        let authorityEnd = suffix.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" }
            ?? suffix.endIndex
        let authority = suffix[..<authorityEnd]
        let remainder = suffix[authorityEnd...]
        let components = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 1 || components.count == 2 else { return false }
        if components.count == 2 {
            guard !components[1].isEmpty,
                  components[1].unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) else {
                return false
            }
        }

        let rawHost = components[0]
        let scalars = Array(rawHost.unicodeScalars)
        let labels = rawHost.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = scalars.first, Self.isASCIIAlphanumeric(first),
              labels.allSatisfy({ !$0.lowercased().hasPrefix("xn--") }),
              scalars.allSatisfy({
                  Self.isASCIIAlphanumeric($0) || $0 == "." || $0 == "-"
              }) else {
            return false
        }

        return requiresPath ? remainder.first == "/" : remainder.isEmpty || remainder.first == "/"
    }

    private static func isASCIIAlphanumeric(_ scalar: UnicodeScalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57) ||
            (scalar.value >= 65 && scalar.value <= 90) ||
            (scalar.value >= 97 && scalar.value <= 122)
    }

    private static func isCanonicalTimestamp(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    private static func isCommit(_ value: String) -> Bool {
        value.count == 40 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }

    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0)
        }
    }

    private static func isUnique<T: Hashable>(_ values: [T]) -> Bool {
        Set(values).count == values.count
    }

    private static func validate(asset: EngineAssetDescriptor, maximumBytes: Int) throws {
        guard isTrustedHTTPSURL(asset.url, requiresPath: true),
              isHash(asset.sha256), asset.byteSize > 0, asset.byteSize <= maximumBytes else {
            throw EngineUpdateError.invalidManifest("invalid asset descriptor")
        }
    }
}

struct EngineInformation: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let engineVersion: EngineVersion
    let repository: URL
    let commit: String
    let checkedAt: String
    let license: String
    let protocolVersions: [Int]
    let minAppBuild: Int
    let maxAppBuild: Int
    let minMacOS: String
    let architectures: [String]
    let capabilities: [String]
}

struct InstalledEngineState: Codable, Equatable, Sendable {
    var active: EngineVersion?
    var previous: EngineVersion?
    var highestAcceptedVersion: EngineVersion?

    init(
        active: EngineVersion?,
        previous: EngineVersion?,
        highestAcceptedVersion: EngineVersion? = nil
    ) {
        self.active = active
        self.previous = previous
        self.highestAcceptedVersion = highestAcceptedVersion
    }

    private enum CodingKeys: String, CodingKey {
        case active
        case previous
        case highestAcceptedVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        active = try container.decodeIfPresent(EngineVersion.self, forKey: .active)
        previous = try container.decodeIfPresent(EngineVersion.self, forKey: .previous)
        highestAcceptedVersion = try container.decodeIfPresent(EngineVersion.self, forKey: .highestAcceptedVersion)
    }

    static let bundled = InstalledEngineState(active: nil, previous: nil)
}

enum EngineProvenance: String, Codable, Equatable, Sendable {
    case downloaded
    case previous
    case bundled
}

struct ResolvedEngine: Codable, Equatable, Sendable {
    let executableURL: URL
    let version: EngineVersion
    let upstreamCommit: String
    let provenance: EngineProvenance
    let sourceURL: URL?
}

struct EngineUpdateCandidate: Codable, Equatable, Sendable {
    let manifest: EngineManifest
    let rawManifest: Data
    let rawSignature: Data
}

enum EngineUpdateStatus: Codable, Equatable, Sendable {
    case disabled(String)
    case bundled(EngineVersion)
    case installed(ResolvedEngine)
    case updateAvailable(EngineUpdateCandidate)
}

struct EngineUpdateConfiguration: Sendable {
    static let liveManifestURL = URL(
        string: "https://github.com/Van426326/SpruceMyMac/releases/download/engine-feed/engine-manifest.json"
    )!
    static let liveSignatureURL = URL(
        string: "https://github.com/Van426326/SpruceMyMac/releases/download/engine-feed/engine-manifest.sig"
    )!

    let manifestURL: URL
    let signatureURL: URL
    let signingPublicKeyBase64: String
    let appBuild: Int
    let currentOS: OperatingSystemVersion
    let architecture: String
    let applicationSupportRoot: URL
    let bundledEngineURL: URL

    static let requiredCapabilities: Set<String> = [
        "clean-plan", "apply-plan", "app-list", "uninstall-plan", "tool-plan"
    ]

    var publicKeyData: Data? {
        let text = signingPublicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("$("), let data = Data(base64Encoded: text), data.count == 32 else {
            return nil
        }
        return data
    }

    var updatesEnabled: Bool { publicKeyData != nil }

    static func live(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        processInfo: ProcessInfo = .processInfo
    ) -> EngineUpdateConfiguration {
        let appBuild = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        let signingKey = bundle.object(forInfoDictionaryKey: "SpruceEngineSigningPublicKey") as? String ?? ""
        let supportBase = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let bundledEngine = bundle.url(
            forResource: "gui",
            withExtension: "sh",
            subdirectory: "Engine/Mole/bin"
        ) ?? bundle.resourceURL?
            .appendingPathComponent("Engine/Mole/bin/gui.sh")
            ?? URL(fileURLWithPath: "/nonexistent/SpruceMyMac/Engine/Mole/bin/gui.sh")

        return EngineUpdateConfiguration(
            manifestURL: liveManifestURL,
            signatureURL: liveSignatureURL,
            signingPublicKeyBase64: signingKey,
            appBuild: appBuild,
            currentOS: processInfo.operatingSystemVersion,
            architecture: currentArchitecture,
            applicationSupportRoot: supportBase.appendingPathComponent("SpruceMyMac", isDirectory: true),
            bundledEngineURL: bundledEngine
        )
    }

    private static var currentArchitecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unsupported"
#endif
    }

    func validateTrustConfiguration() throws {
        guard EngineManifest.isTrustedHTTPSURL(manifestURL, requiresPath: true),
              EngineManifest.isTrustedHTTPSURL(signatureURL, requiresPath: true) else {
            throw EngineUpdateError.invalidConfiguration("feed URLs must use HTTPS")
        }
        guard publicKeyData != nil else { throw EngineUpdateError.updatesDisabled }
        guard appBuild > 0, architecture == "arm64" || architecture == "x86_64" else {
            throw EngineUpdateError.invalidConfiguration("invalid build or architecture")
        }
    }
}

extension OperatingSystemVersion {
    init?(engineString: String) {
        let parts = engineString.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]),
              major >= 0, minor >= 0, String(major) == parts[0], String(minor) == parts[1] else {
            return nil
        }
        self.init(majorVersion: major, minorVersion: minor, patchVersion: 0)
    }
}

enum EngineUpdateError: Codable, Error, Equatable, Sendable, LocalizedError {
    case updatesDisabled
    case invalidConfiguration(String)
    case unsupportedSchema(Int)
    case invalidManifest(String)
    case invalidSignature
    case incompatibleAppBuild
    case incompatibleProtocol
    case missingCapability(String)
    case incompatibleOperatingSystem
    case incompatibleArchitecture
    case downgradeRejected
    case operationInProgress
    case downloadTooLarge
    case assetSizeMismatch
    case assetHashMismatch
    case unsafeArchive(String)
    case invalidPayload(String)
    case handshakeFailed(String)
    case stateCorrupt
    case noEngineAvailable

    var errorDescription: String? {
        switch self {
        case .updatesDisabled: "引擎更新尚未配置。"
        case let .invalidConfiguration(reason): "引擎更新配置无效：\(reason)"
        case .unsupportedSchema: "不支持该引擎清单格式。"
        case let .invalidManifest(reason): "引擎清单无效：\(reason)"
        case .invalidSignature: "引擎更新签名验证失败。"
        case .incompatibleAppBuild: "该引擎与当前应用版本不兼容。"
        case .incompatibleProtocol: "该引擎协议与当前应用不兼容。"
        case let .missingCapability(capability): "该引擎缺少必要能力：\(capability)"
        case .incompatibleOperatingSystem: "该引擎不支持当前 macOS。"
        case .incompatibleArchitecture: "该引擎不支持当前 Mac 架构。"
        case .downgradeRejected: "拒绝安装旧版本引擎。"
        case .operationInProgress: "另一项引擎更新操作正在进行。"
        case .downloadTooLarge: "引擎下载超过安全大小限制。"
        case .assetSizeMismatch: "引擎下载大小不匹配。"
        case .assetHashMismatch: "引擎下载校验失败。"
        case let .unsafeArchive(path): "引擎归档包含不安全路径：\(path)"
        case let .invalidPayload(reason): "引擎文件验证失败：\(reason)"
        case let .handshakeFailed(reason): "引擎兼容性检查失败：\(reason)"
        case .stateCorrupt: "引擎状态文件损坏。"
        case .noEngineAvailable: "没有可用的清理引擎。"
        }
    }
}
