// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Security

enum SprucePrivilegedHelperConstants {
    static let protocolVersion = 1
    static let serviceIdentifier = "com.van426326.sprucemymac.helper"
    static let plistName = "com.van426326.sprucemymac.helper.plist"
    static let executableName = "sprucemymac-helper"
    static let applicationIdentifier = "com.van426326.sprucemymac"
}

@objc protocol SprucePrivilegedHelperProtocol {
    func helperVersion(withReply reply: @escaping (Int) -> Void)
    func availableTaskIdentifiers(withReply reply: @escaping ([String]) -> Void)
    func runTask(
        _ taskIdentifier: String,
        requestIdentifier: String,
        withReply reply: @escaping (NSDictionary?, NSError?) -> Void
    )
}

enum SystemMaintenanceTask: String, CaseIterable, Identifiable, Sendable {
    case flushDNSCache = "flush-dns-cache"
    case rebuildSpotlightIndex = "rebuild-spotlight-index"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flushDNSCache: String(localized: "刷新 DNS 缓存")
        case .rebuildSpotlightIndex: String(localized: "重建 Spotlight 索引")
        }
    }

    var detail: String {
        switch self {
        case .flushDNSCache:
            String(localized: "清空系统 DNS 缓存并让 mDNSResponder 重新加载；不会修改网络设置。")
        case .rebuildSpotlightIndex:
            String(localized: "要求 Spotlight 重建启动磁盘索引；完成前可能产生较高磁盘活动。")
        }
    }

    var confirmation: String {
        switch self {
        case .flushDNSCache:
            String(localized: "现有 DNS 缓存会被清空，首次访问域名时会重新查询。")
        case .rebuildSpotlightIndex:
            String(localized: "Spotlight 将重新索引启动磁盘，期间搜索结果可能不完整。")
        }
    }

    var risk: MaintenanceTaskRisk {
        switch self {
        case .flushDNSCache: .low
        case .rebuildSpotlightIndex: .review
        }
    }

    var responseTimeoutSeconds: Int {
        guard let definition = SystemMaintenanceTaskCatalog.definition(for: rawValue) else {
            return 45
        }
        return definition.commands.reduce(5) { total, command in
            total + command.timeoutSeconds + 3
        }
    }
}

enum MaintenanceTaskRisk: String, Sendable {
    case low
    case review
}

struct FixedSystemCommand: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
    let timeoutSeconds: Int
}

struct SystemMaintenanceTaskDefinition: Equatable, Sendable {
    let task: SystemMaintenanceTask
    let commands: [FixedSystemCommand]
}

enum SystemMaintenanceTaskCatalog {
    static let definitions: [SystemMaintenanceTaskDefinition] = [
        SystemMaintenanceTaskDefinition(
            task: .flushDNSCache,
            commands: [
                FixedSystemCommand(
                    executablePath: "/usr/bin/dscacheutil",
                    arguments: ["-flushcache"],
                    timeoutSeconds: 10
                ),
                FixedSystemCommand(
                    executablePath: "/usr/bin/killall",
                    arguments: ["-HUP", "mDNSResponder"],
                    timeoutSeconds: 10
                )
            ]
        ),
        SystemMaintenanceTaskDefinition(
            task: .rebuildSpotlightIndex,
            commands: [
                FixedSystemCommand(
                    executablePath: "/usr/bin/mdutil",
                    arguments: ["-E", "/"],
                    timeoutSeconds: 30
                )
            ]
        )
    ]

    static func definition(for identifier: String) -> SystemMaintenanceTaskDefinition? {
        definitions.first { $0.task.rawValue == identifier }
    }

    static var taskIdentifiers: [String] {
        definitions.map(\.task.rawValue)
    }
}

enum PrivilegedRequestValidator {
    static func canonicalRequestIdentifier(_ value: String) -> String? {
        guard value.count == 36,
              let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value.lowercased() else {
            return nil
        }
        return uuid.uuidString.lowercased()
    }

    static func task(for identifier: String) -> SystemMaintenanceTaskDefinition? {
        guard identifier.count <= 64,
              identifier.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz-").contains($0)
              }) else {
            return nil
        }
        return SystemMaintenanceTaskCatalog.definition(for: identifier)
    }
}

struct MaintenanceTaskResult: Equatable, Sendable {
    let protocolVersion: Int
    let requestIdentifier: String
    let taskIdentifier: String
    let succeeded: Bool
    let startedAt: Date
    let finishedAt: Date
    let exitCodes: [Int32]
    let messageKey: String

    init(dictionary: NSDictionary) throws {
        guard let protocolVersion = dictionary["protocol"] as? Int,
              protocolVersion == SprucePrivilegedHelperConstants.protocolVersion,
              let requestIdentifier = dictionary["request_id"] as? String,
              PrivilegedRequestValidator.canonicalRequestIdentifier(requestIdentifier) != nil,
              let taskIdentifier = dictionary["task_id"] as? String,
              PrivilegedRequestValidator.task(for: taskIdentifier) != nil,
              let succeeded = dictionary["succeeded"] as? Bool,
              let startedTimestamp = dictionary["started_at"] as? TimeInterval,
              let finishedTimestamp = dictionary["finished_at"] as? TimeInterval,
              finishedTimestamp >= startedTimestamp,
              let numberCodes = dictionary["exit_codes"] as? [NSNumber],
              numberCodes.count <= 4,
              let messageKey = dictionary["message_key"] as? String,
              ["helper.task.completed", "helper.task.failed"].contains(messageKey),
              !succeeded || numberCodes.allSatisfy({ $0.int32Value == 0 }) else {
            throw PrivilegedHelperError.invalidResponse
        }

        self.protocolVersion = protocolVersion
        self.requestIdentifier = requestIdentifier
        self.taskIdentifier = taskIdentifier
        self.succeeded = succeeded
        startedAt = Date(timeIntervalSince1970: startedTimestamp)
        finishedAt = Date(timeIntervalSince1970: finishedTimestamp)
        exitCodes = numberCodes.map(\.int32Value)
        self.messageKey = messageKey
    }
}

enum PrivilegedHelperError: LocalizedError {
    case missingBundledComponent(String)
    case invalidCodeSignature(OSStatus)
    case missingCodeSigningRequirement
    case invalidResponse
    case mismatchedResponse
    case connectionFailed(String)
    case connectionTimedOut
    case connectionInterrupted
    case responseTimedOut
    case serviceUnavailable

    var errorDescription: String? {
        switch self {
        case let .missingBundledComponent(name): String(localized: "应用包缺少必要组件：\(name)")
        case let .invalidCodeSignature(status): String(localized: "无法验证代码签名（\(status)）")
        case .missingCodeSigningRequirement: String(localized: "无法读取组件的指定代码签名要求")
        case .invalidResponse: String(localized: "Helper 返回了无效响应")
        case .mismatchedResponse: String(localized: "Helper 响应与请求不匹配")
        case let .connectionFailed(message): String(localized: "无法连接 Helper：\(message)")
        case .connectionTimedOut: String(localized: "Helper 连接超时；请检查签名、公证和系统批准状态。")
        case .connectionInterrupted: String(localized: "Helper 连接已中断。")
        case .responseTimedOut: String(localized: "Helper 任务超时，连接已安全关闭。")
        case .serviceUnavailable: String(localized: "Helper 尚未启用或未获系统批准")
        }
    }
}

enum CodeSigningRequirementReader {
    static func satisfies(requirement requirementString: String, for url: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return false
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementString as CFString,
            [],
            &requirement
        ) == errSecSuccess,
        let requirement else {
            return false
        }

        return SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures)),
            requirement
        ) == errSecSuccess
    }

    static func designatedRequirement(for url: URL) throws -> String {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw PrivilegedHelperError.invalidCodeSignature(status)
        }

        var requirement: SecRequirement?
        status = SecCodeCopyDesignatedRequirement(staticCode, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw PrivilegedHelperError.invalidCodeSignature(status)
        }

        var requirementString: CFString?
        status = SecRequirementCopyString(requirement, [], &requirementString)
        guard status == errSecSuccess, let requirementString else {
            throw PrivilegedHelperError.missingCodeSigningRequirement
        }
        return requirementString as String
    }
}
