// SPDX-License-Identifier: GPL-3.0-only

@preconcurrency import Foundation
import ServiceManagement

enum PrivilegedHelperState: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .notFound
        }
    }

    var title: String {
        switch self {
        case .notRegistered: String(localized: "尚未安装")
        case .enabled: String(localized: "已启用")
        case .requiresApproval: String(localized: "等待系统批准")
        case .notFound: String(localized: "服务未就绪")
        }
    }
}

enum PrivilegedHelperManagerError: LocalizedError {
    case applicationMustBeInstalled
    case applicationMustBeNotarized
    case missingComponents

    var errorDescription: String? {
        switch self {
        case .applicationMustBeInstalled: String(localized: "请先将 SpruceMyMac 移到 /Applications，再安装系统 Helper。")
        case .applicationMustBeNotarized: String(localized: "系统 Helper 需要 Developer ID 签名并经过 Apple 公证的 SpruceMyMac。")
        case .missingComponents: String(localized: "应用包中的 Helper 或 LaunchDaemon 配置不完整。")
        }
    }
}

final class PrivilegedReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MaintenanceTaskResult, Error>?
    var connection: NSXPCConnection?

    init(_ continuation: CheckedContinuation<MaintenanceTaskResult, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<MaintenanceTaskResult, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let connection = connection
        self.connection = nil
        lock.unlock()

        connection?.invalidate()
        continuation.resume(with: result)
    }

    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation != nil
    }
}

struct PrivilegedHelperClient: Sendable {
    let helperExecutableURL: URL

    func run(task: SystemMaintenanceTask) async throws -> MaintenanceTaskResult {
        let requestIdentifier = UUID().uuidString.lowercased()
        return try await withCheckedThrowingContinuation { continuation in
            let gate = PrivilegedReplyGate(continuation)
            do {
                let helperRequirement = try CodeSigningRequirementReader.designatedRequirement(
                    for: helperExecutableURL
                )
                let connection = NSXPCConnection(
                    machServiceName: SprucePrivilegedHelperConstants.serviceIdentifier,
                    options: .privileged
                )
                gate.connection = connection
                connection.remoteObjectInterface = NSXPCInterface(
                    with: SprucePrivilegedHelperProtocol.self
                )
                connection.setCodeSigningRequirement(helperRequirement)
                connection.interruptionHandler = {
                    gate.finish(.failure(PrivilegedHelperError.connectionInterrupted))
                }
                connection.invalidationHandler = {
                    gate.finish(.failure(PrivilegedHelperError.connectionInterrupted))
                }
                connection.activate()

                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    gate.finish(.failure(PrivilegedHelperError.connectionFailed(error.localizedDescription)))
                }) as? SprucePrivilegedHelperProtocol else {
                    gate.finish(.failure(PrivilegedHelperError.serviceUnavailable))
                    return
                }

                let connectionTimeout = DispatchWorkItem {
                    gate.finish(.failure(PrivilegedHelperError.connectionTimedOut))
                }
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + .seconds(5),
                    execute: connectionTimeout
                )

                proxy.helperVersion { version in
                    connectionTimeout.cancel()
                    guard gate.isPending else { return }
                    guard version == SprucePrivilegedHelperConstants.protocolVersion else {
                        gate.finish(.failure(PrivilegedHelperError.invalidResponse))
                        return
                    }

                    let responseTimeout = DispatchWorkItem {
                        gate.finish(.failure(PrivilegedHelperError.responseTimedOut))
                    }
                    DispatchQueue.global(qos: .utility).asyncAfter(
                        deadline: .now() + .seconds(task.responseTimeoutSeconds),
                        execute: responseTimeout
                    )

                    proxy.runTask(
                        task.rawValue,
                        requestIdentifier: requestIdentifier
                    ) { dictionary, error in
                        responseTimeout.cancel()
                        do {
                            guard let dictionary else {
                                throw error ?? PrivilegedHelperError.invalidResponse
                            }
                            let result = try MaintenanceTaskResult(dictionary: dictionary)
                            guard result.requestIdentifier == requestIdentifier,
                                  result.taskIdentifier == task.rawValue else {
                                throw PrivilegedHelperError.mismatchedResponse
                            }
                            gate.finish(.success(result))
                        } catch {
                            gate.finish(.failure(error))
                        }
                    }
                }
            } catch {
                gate.finish(.failure(error))
            }
        }
    }
}

@MainActor
final class PrivilegedHelperManager: ObservableObject {
    @Published private(set) var state: PrivilegedHelperState = .notRegistered
    @Published private(set) var isWorking = false
    @Published private(set) var activeTask: SystemMaintenanceTask?
    @Published private(set) var lastResult: MaintenanceTaskResult?
    @Published var errorMessage: String?

    private let service = SMAppService.daemon(
        plistName: SprucePrivilegedHelperConstants.plistName
    )
    private let historyStore = CleanupHistoryStore.shared

    var applicationIsInstalled: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return path == "/Applications/SpruceMyMac.app" || path.hasPrefix("/Applications/")
    }

    var applicationIsNotarized: Bool {
        CodeSigningRequirementReader.satisfies(
            requirement: "notarized",
            for: Bundle.main.bundleURL
        )
    }

    var helperExecutableURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/HelperTools", isDirectory: true)
            .appendingPathComponent(SprucePrivilegedHelperConstants.executableName)
    }

    var launchDaemonPlistURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
            .appendingPathComponent(SprucePrivilegedHelperConstants.plistName)
    }

    var bundledComponentsAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: helperExecutableURL.path) &&
            FileManager.default.fileExists(atPath: launchDaemonPlistURL.path)
    }

    init() {
        refresh()
    }

    func refresh() {
        state = PrivilegedHelperState(service.status)
    }

    func register() {
        guard applicationIsInstalled else {
            errorMessage = PrivilegedHelperManagerError.applicationMustBeInstalled.localizedDescription
            return
        }
        guard applicationIsNotarized else {
            errorMessage = PrivilegedHelperManagerError.applicationMustBeNotarized.localizedDescription
            return
        }
        guard bundledComponentsAvailable else {
            errorMessage = PrivilegedHelperManagerError.missingComponents.localizedDescription
            return
        }

        isWorking = true
        defer { isWorking = false }
        do {
            try service.register()
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func unregister() {
        isWorking = true
        defer { isWorking = false }
        do {
            try service.unregister()
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func run(_ task: SystemMaintenanceTask) async {
        guard state == .enabled else {
            errorMessage = PrivilegedHelperError.serviceUnavailable.localizedDescription
            return
        }
        guard bundledComponentsAvailable else {
            errorMessage = PrivilegedHelperManagerError.missingComponents.localizedDescription
            return
        }

        isWorking = true
        activeTask = task
        defer {
            activeTask = nil
            isWorking = false
            refresh()
        }

        do {
            let result = try await PrivilegedHelperClient(
                helperExecutableURL: helperExecutableURL
            ).run(task: task)
            lastResult = result
            let succeeded = result.succeeded ? 1 : 0
            let record = CleanupHistoryRecord(
                id: UUID(),
                operation: .maintenance,
                planID: result.requestIdentifier,
                finishedAt: result.finishedAt,
                selectedCount: 1,
                succeededCount: succeeded,
                failedCount: 1 - succeeded,
                freedBytes: 0,
                outcome: result.succeeded ? .completed : .failed
            )
            try? await historyStore.append(record)
            if !result.succeeded {
                errorMessage = String(localized: "系统维护任务未能完成。")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
