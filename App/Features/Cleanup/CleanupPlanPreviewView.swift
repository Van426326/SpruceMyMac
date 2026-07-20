// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

struct CleanupPlanPreviewView: View {
    let plan: CleanupPlan
    let onApplied: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var validationState = ValidationState.validating
    @State private var applyState = ApplyState.ready
    @State private var showsConfirmation = false

    private let validator = CleanupPlanValidator()
    private let engine = BundledMoleBridge()
    private let historyStore = CleanupHistoryStore.shared

    private enum ValidationState: Equatable {
        case validating
        case valid
        case invalid(String)
    }

    private enum ApplyState: Equatable {
        case ready
        case applying
        case completed(freedBytes: Int64, failedCount: Int)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(plan.candidates) { candidate in
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox")
                        .foregroundStyle(SpruceTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(candidate.name).font(.body.weight(.medium))
                        Text(candidate.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(ByteFormatting.string(candidate.size))
                        .monospacedDigit()
                }
                .padding(.vertical, 5)
            }
            .listStyle(.inset)
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 520)
        .task {
            let result = await validator.validate(plan)
            switch result {
            case .success:
                validationState = .valid
            case let .failure(error):
                validationState = .invalid(message(for: error))
            }
        }
        .confirmationDialog(
            "确认移入废纸篓？",
            isPresented: $showsConfirmation,
            titleVisibility: .visible
        ) {
            Button("移入废纸篓", role: .destructive) {
                applyPlan()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将处理 \(plan.candidates.count) 项、\(ByteFormatting.string(plan.totalBytes))。执行前会再次验证路径和文件指纹。")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("清理计划预览")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("\(plan.candidates.count) 项，共 \(ByteFormatting.string(plan.totalBytes))")
                    .foregroundStyle(.secondary)
                if let enginePlanID = plan.enginePlanID {
                    Text("引擎计划 · \(enginePlanID)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(applyState == .applying)
        }
        .padding(24)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            statusLabel
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("计划将在 \(plan.expiresAt, style: .relative)失效")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                executionDetail
            }
            Button(applyState == .applying ? String(localized: "正在移动…") : String(localized: "移入废纸篓")) {
                showsConfirmation = true
            }
                .buttonStyle(.borderedProminent)
                .disabled(!canApply)
        }
        .padding(20)
        .background(.bar)
    }

    @ViewBuilder
    private var statusLabel: some View {
        if case let .completed(freedBytes, failedCount) = applyState {
            Label {
                Text(failedCount == 0
                    ? String(localized: "已移入废纸篓 · \(ByteFormatting.string(freedBytes))")
                    : String(localized: "部分完成，\(failedCount) 项失败"))
            } icon: {
                Image(systemName: failedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            }
            .foregroundStyle(failedCount == 0 ? SpruceTheme.accent : .orange)
        } else if case let .failed(message) = applyState {
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        } else if applyState == .applying {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在执行安全计划")
            }
        } else {
        switch validationState {
        case .validating:
            Label("正在校验文件状态", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .valid:
            Label("路径与文件指纹有效", systemImage: "checkmark.shield.fill")
                .foregroundStyle(SpruceTheme.accent)
        case let .invalid(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        }
    }

    @ViewBuilder
    private var executionDetail: some View {
        switch applyState {
        case .ready:
            Text(plan.enginePlanID == nil
                ? String(localized: "未连接内置引擎，仅可预览")
                : String(localized: "仅接受此计划中的候选 ID"))
                .font(.caption.weight(.medium))
                .foregroundStyle(plan.enginePlanID == nil ? .orange : SpruceTheme.accent)
        case .applying:
            Text("请勿退出应用")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
        case .completed:
            Text("可从废纸篓恢复")
                .font(.caption.weight(.medium))
                .foregroundStyle(SpruceTheme.accent)
        case .failed:
            Text("未继续处理剩余项目")
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
        }
    }

    private var canApply: Bool {
        validationState == .valid && applyState == .ready && plan.enginePlanID != nil
    }

    private func message(for error: CleanupPlanValidator.ValidationError) -> String {
        switch error {
        case .expired: String(localized: "计划已失效，请重新扫描")
        case .empty: String(localized: "计划中没有候选项")
        case .duplicateCandidate: String(localized: "计划包含重复候选项")
        case .pathOutsideAllowedRoot: String(localized: "计划包含不允许的路径")
        case .pathChanged: String(localized: "文件状态已变化，请重新扫描")
        }
    }

    private func applyPlan() {
        guard let planID = plan.enginePlanID else { return }
        applyState = .applying

        Task {
            let validation = await validator.validate(plan)
            guard case .success = validation else {
                applyState = .failed(String(localized: "文件状态已变化，请重新扫描"))
                return
            }

            do {
                let events = try await engine.applyPlanEvents(
                    planID: planID,
                    candidateIDs: plan.candidates.map(\.id)
                )
                let record = CleanupHistoryRecord.make(plan: plan, events: events)
                try? await historyStore.append(record)
                applyState = .completed(
                    freedBytes: record.freedBytes,
                    failedCount: record.failedCount
                )
                onApplied()
            } catch is CancellationError {
                applyState = .failed(String(localized: "操作已取消"))
            } catch {
                applyState = .failed(String(localized: "计划执行失败，文件未被永久删除"))
            }
        }
    }
}
