// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

struct SystemMaintenanceView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = PrivilegedHelperManager()
    @State private var taskAwaitingConfirmation: SystemMaintenanceTask?
    @State private var confirmsUnregister = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 18) {
                    serviceCard
                    ForEach(SystemMaintenanceTask.allCases) { task in
                        taskCard(task)
                    }
                    securityNote
                }
                .padding(24)
            }
        }
        .frame(minWidth: 720, minHeight: 620)
        .onAppear { manager.refresh() }
        .confirmationDialog(
            taskAwaitingConfirmation?.title ?? String(localized: "确认系统维护任务？"),
            isPresented: Binding(
                get: { taskAwaitingConfirmation != nil },
                set: { if !$0 { taskAwaitingConfirmation = nil } }
            ),
            presenting: taskAwaitingConfirmation
        ) { task in
            Button(task.title, role: task.risk == .review ? .destructive : nil) {
                Task { await manager.run(task) }
            }
            Button("取消", role: .cancel) { taskAwaitingConfirmation = nil }
        } message: { task in
            Text(task.confirmation)
        }
        .confirmationDialog("移除系统 Helper？", isPresented: $confirmsUnregister) {
            Button("移除 Helper", role: .destructive) { manager.unregister() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("移除后系统维护任务将不可用，可随时重新安装。")
        }
        .alert("系统维护", isPresented: Binding(
            get: { manager.errorMessage != nil },
            set: { if !$0 { manager.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { manager.errorMessage = nil }
        } message: {
            Text(manager.errorMessage ?? String(localized: "未知错误"))
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("系统维护")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("受代码签名约束的固定任务，不接受路径或命令参数。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("关闭") { dismiss() }
                .disabled(manager.isWorking)
        }
        .padding(24)
    }

    private var serviceCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: stateSymbol)
                    .font(.title2)
                    .foregroundStyle(stateColor)
                    .frame(width: 44, height: 44)
                    .background(stateColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("系统 Helper").font(.headline)
                    Text(serviceStateTitle).foregroundStyle(.secondary)
                }
                Spacer()
                if manager.isWorking { ProgressView().controlSize(.small) }
                serviceActions
            }

            if !manager.applicationIsInstalled {
                Label("正式启用前请将应用移到 /Applications。", systemImage: "folder.badge.questionmark")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if !manager.applicationIsNotarized {
                Label("系统 Helper 需要 Developer ID 签名并经过 Apple 公证。", systemImage: "signature")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if !manager.bundledComponentsAvailable {
                Label("应用包中的 Helper 组件不完整。", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .cardSurface()
    }

    @ViewBuilder
    private var serviceActions: some View {
        switch manager.state {
        case .notRegistered:
            Button("安装 Helper") { manager.register() }
                .buttonStyle(.borderedProminent)
                .disabled(!manager.applicationIsInstalled || !manager.applicationIsNotarized || manager.isWorking)
        case .requiresApproval:
            Button("打开系统设置") { manager.openApprovalSettings() }
                .buttonStyle(.borderedProminent)
        case .enabled:
            Button("移除…") { confirmsUnregister = true }
                .disabled(manager.isWorking)
        case .notFound:
            Button("安装 Helper") { manager.register() }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !manager.applicationIsInstalled || !manager.applicationIsNotarized ||
                    !manager.bundledComponentsAvailable || manager.isWorking
                )
        }
    }

    private func taskCard(_ task: SystemMaintenanceTask) -> some View {
        HStack(spacing: 16) {
            Image(systemName: task == .flushDNSCache ? "network" : "magnifyingglass.circle")
                .font(.title2)
                .foregroundStyle(task.risk == .low ? SpruceTheme.accent : .orange)
                .frame(width: 46, height: 46)
                .background(
                    (task.risk == .low ? SpruceTheme.accent : Color.orange).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 13)
                )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(task.title).font(.headline)
                    Text(task.risk == .low ? String(localized: "低风险") : String(localized: "需确认"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(task.risk == .low ? SpruceTheme.accent : .orange)
                }
                Text(task.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if manager.activeTask == task {
                ProgressView().controlSize(.small)
            } else {
                Button("运行…") { taskAwaitingConfirmation = task }
                    .disabled(manager.state != .enabled || manager.isWorking)
            }
        }
        .padding(20)
        .cardSurface()
    }

    private var securityNote: some View {
        Label(
            "Helper 仅识别内置任务 ID，并使用固定绝对路径和参数。App 与 Helper 在 XPC 建连前会互相验证指定代码签名要求。",
            systemImage: "checkmark.shield"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(4)
    }

    private var stateSymbol: String {
        if !manager.applicationIsInstalled { return "shippingbox" }
        return switch manager.state {
        case .enabled: "checkmark.shield.fill"
        case .requiresApproval: "person.badge.key"
        case .notRegistered: "lock.open"
        case .notFound: "exclamationmark.shield"
        }
    }

    private var stateColor: Color {
        if !manager.applicationIsInstalled { return .orange }
        return switch manager.state {
        case .enabled: SpruceTheme.accent
        case .requiresApproval, .notRegistered: .orange
        case .notFound: .red
        }
    }

    private var serviceStateTitle: String {
        if !manager.applicationIsInstalled { return String(localized: "等待放入 /Applications") }
        if !manager.applicationIsNotarized { return String(localized: "需要公证版本") }
        if !manager.bundledComponentsAvailable { return String(localized: "组件不完整") }
        return manager.state.title
    }
}
