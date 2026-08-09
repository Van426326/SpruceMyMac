// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Process-wide live composition. Every default bridge resolves through the
/// same actor, while the updater activates versions through the same state.
enum EngineUpdateRuntime {
    static let configuration = EngineUpdateConfiguration.live()
    static let resolver = EngineResolver(configuration: configuration)
    static let service = EngineUpdateService(configuration: configuration, resolver: resolver)
}

@MainActor
final class EngineUpdateViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case refreshing
        case checking
        case installing
        case restoring
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentEngine: ResolvedEngine?
    @Published private(set) var candidate: EngineUpdateCandidate?
    @Published private(set) var noticeMessage: String?
    @Published private(set) var errorMessage: String?

    let updatesEnabled: Bool
    private let service: any EngineUpdating

    init(service: any EngineUpdating, updatesEnabled: Bool) {
        self.service = service
        self.updatesEnabled = updatesEnabled
    }

    convenience init() {
        self.init(
            service: EngineUpdateRuntime.service,
            updatesEnabled: EngineUpdateRuntime.configuration.updatesEnabled
        )
    }

    var isBusy: Bool { phase != .idle }
    var canRestoreBundled: Bool {
        guard let provenance = currentEngine?.provenance else { return false }
        return provenance == .downloaded || provenance == .previous
    }

    var phaseMessage: String? {
        switch phase {
        case .idle: nil
        case .refreshing: String(localized: "正在读取引擎状态…")
        case .checking: String(localized: "正在检查引擎更新…")
        case .installing: String(localized: "正在下载、验证并安装引擎…")
        case .restoring: String(localized: "正在恢复内置引擎…")
        }
    }

    var provenanceDescription: String? {
        switch currentEngine?.provenance {
        case .downloaded: String(localized: "已下载并验证")
        case .previous: String(localized: "已回退到上一版本")
        case .bundled: String(localized: "应用内置")
        case nil: nil
        }
    }

    func refreshCurrent() async {
        guard begin(.refreshing) else { return }
        defer { phase = .idle }
        do {
            currentEngine = try await service.currentEngine()
        } catch {
            errorMessage = Self.message(for: error, action: .refreshing)
        }
    }

    func checkForUpdate() async {
        guard updatesEnabled else {
            noticeMessage = String(localized: "引擎更新尚未配置；当前将继续使用已验证的本地引擎。")
            return
        }
        guard begin(.checking) else { return }
        candidate = nil
        defer { phase = .idle }
        do {
            let update = try await service.checkForUpdate()
            candidate = update
            noticeMessage = String(localized: "发现经过签名验证的引擎更新。")
        } catch EngineUpdateError.downgradeRejected {
            candidate = nil
            noticeMessage = String(localized: "当前已是最新兼容引擎。")
        } catch {
            errorMessage = Self.message(for: error, action: .checking)
        }
    }

    func installCandidate() async {
        guard let candidate, begin(.installing) else { return }
        defer { phase = .idle }
        do {
            currentEngine = try await service.install(candidate)
            self.candidate = nil
            noticeMessage = String(localized: "引擎更新已安装，将用于下一次操作。")
        } catch {
            errorMessage = Self.message(for: error, action: .installing)
        }
    }

    func restoreBundled() async {
        guard begin(.restoring) else { return }
        defer { phase = .idle }
        do {
            currentEngine = try await service.restoreBundled()
            candidate = nil
            noticeMessage = String(localized: "已恢复应用内置引擎。")
        } catch {
            errorMessage = Self.message(for: error, action: .restoring)
        }
    }

    private func begin(_ newPhase: Phase) -> Bool {
        guard phase == .idle else { return false }
        phase = newPhase
        errorMessage = nil
        noticeMessage = nil
        return true
    }

    private enum Action {
        case refreshing
        case checking
        case installing
        case restoring
    }

    private static func message(for error: Error, action: Action) -> String {
        if let updateError = error as? EngineUpdateError {
            switch updateError {
            case .updatesDisabled, .invalidConfiguration:
                return String(localized: "引擎更新尚未配置或配置无效。")
            case .invalidSignature, .assetHashMismatch, .assetSizeMismatch,
                 .unsafeArchive, .invalidPayload, .handshakeFailed:
                return String(localized: "引擎更新未通过安全验证，未进行安装。")
            case .incompatibleAppBuild, .incompatibleProtocol, .missingCapability,
                 .incompatibleOperatingSystem, .incompatibleArchitecture, .unsupportedSchema:
                return String(localized: "该引擎更新与当前应用或系统不兼容。")
            case .downgradeRejected:
                return String(localized: "拒绝安装相同或更旧的引擎版本。")
            case .operationInProgress:
                return String(localized: "另一项引擎更新操作正在进行，请稍后重试。")
            case .downloadTooLarge:
                return String(localized: "引擎更新文件超过安全大小限制。")
            case .invalidManifest:
                return String(localized: "引擎更新清单无效。")
            case .stateCorrupt, .noEngineAvailable:
                return String(localized: "无法读取可用的清理引擎。")
            }
        }
        switch action {
        case .refreshing:
            return String(localized: "无法读取当前引擎状态。")
        case .checking:
            return String(localized: "检查引擎更新失败，请稍后重试。")
        case .installing:
            return String(localized: "安装引擎更新失败，当前引擎保持不变。")
        case .restoring:
            return String(localized: "恢复内置引擎失败。")
        }
    }
}
