// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

struct ApplicationUninstallView: View {
    private struct Candidate: Identifiable {
        let id: String
        let name: String
        let path: String
        let size: Int64
        let category: String
        let risk: String
        let isRequired: Bool
        var isSelected: Bool
    }

    let application: InstalledApplication
    let onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [Candidate] = []
    @State private var planHeader: EnginePlanHeader?
    @State private var isLoading = true
    @State private var isApplying = false
    @State private var showsConfirmation = false
    @State private var errorMessage: String?

    private let engine = BundledMoleBridge()
    private let historyStore = CleanupHistoryStore.shared

    private var selectedCandidates: [Candidate] { candidates.filter(\.isSelected) }
    private var selectedSize: Int64 { selectedCandidates.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 560)
        .task { await loadPlan() }
        .confirmationDialog("确认卸载 \(application.name)？", isPresented: $showsConfirmation) {
            Button("移入废纸篓", role: .destructive) { applyPlan() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将移动 \(selectedCandidates.count) 项、\(ByteFormatting.string(selectedSize))。高风险用户数据只有手动勾选后才会处理。")
        }
    }

    private var header: some View {
        HStack(spacing: 15) {
            Image(nsImage: application.icon)
                .resizable()
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text("卸载 \(application.name)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(application.bundleID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("关闭") { dismiss() }
                .disabled(isApplying)
        }
        .padding(24)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("正在查找精确关联文件…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView("无法生成卸载计划", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
        } else {
            List {
                ForEach($candidates) { $candidate in
                    HStack(spacing: 12) {
                        Toggle("", isOn: $candidate.isSelected)
                            .labelsHidden()
                            .disabled(candidate.isRequired)
                        Image(systemName: icon(for: candidate.category))
                            .foregroundStyle(candidate.risk == "high" ? .orange : SpruceTheme.accent)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(candidate.name).font(.body.weight(.medium))
                                riskBadge(candidate.risk)
                            }
                            Text(candidate.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(ByteFormatting.string(candidate.size)).monospacedDigit()
                    }
                    .padding(.vertical, 6)
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("已选择 \(selectedCandidates.count) 项 · \(ByteFormatting.string(selectedSize))")
                    .font(.headline)
                Text("应用与选中残留将进入废纸篓，可手动恢复。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isApplying { ProgressView().controlSize(.small) }
            Button(isApplying ? String(localized: "正在卸载…") : String(localized: "卸载")) {
                showsConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading || isApplying || selectedCandidates.isEmpty || planHeader == nil)
        }
        .padding(20)
        .background(.bar)
    }

    @ViewBuilder
    private func riskBadge(_ risk: String) -> some View {
        if risk == "high" {
            Text("用户数据")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.orange.opacity(0.1), in: Capsule())
        } else if risk == "review" {
            Text("需确认").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func icon(for category: String) -> String {
        switch category {
        case "application": "app.dashed"
        case "cache": "shippingbox"
        case "settings": "gearshape"
        default: "person.crop.circle.badge.exclamationmark"
        }
    }

    @MainActor
    private func loadPlan() async {
        do {
            let events = try await engine.uninstallPlanEvents(
                inventoryID: application.inventoryID,
                applicationID: application.id
            )
            planHeader = events.compactMap { event -> EnginePlanHeader? in
                guard case let .started(header) = event else { return nil }
                return header
            }.first
            candidates = events.compactMap { event in
                guard case let .uninstallCandidate(candidate) = event else { return nil }
                return Candidate(
                    id: candidate.id,
                    name: candidate.name,
                    path: candidate.path,
                    size: candidate.size,
                    category: candidate.category,
                    risk: candidate.risk,
                    isRequired: candidate.category == "application",
                    isSelected: candidate.defaultSelected
                )
            }
        } catch {
            errorMessage = String(localized: "应用已变化、受保护，或清单已经失效。")
        }
        isLoading = false
    }

    private func applyPlan() {
        guard let planID = planHeader?.planID else { return }
        isApplying = true
        Task {
            do {
                let events = try await engine.applyPlanEvents(
                    planID: planID,
                    candidateIDs: selectedCandidates.map(\.id)
                )
                let record = CleanupHistoryRecord.make(
                    operation: .uninstall,
                    planID: planID,
                    selectedCount: selectedCandidates.count,
                    events: events
                )
                try? await historyStore.append(record)
                isApplying = false
                onCompleted()
            } catch {
                isApplying = false
                errorMessage = String(localized: "卸载计划执行失败；引擎不会回退到永久删除。")
            }
        }
    }
}
