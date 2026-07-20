// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

struct ToolPlanView: View {
    private struct Candidate: Identifiable {
        let id: String
        let name: String
        let path: String
        let size: Int64
        let risk: String
        var isSelected: Bool
    }

    let tool: ToolboxEngineTool
    @Environment(\.dismiss) private var dismiss
    @State private var header: EnginePlanHeader?
    @State private var candidates: [Candidate] = []
    @State private var isLoading = true
    @State private var isApplying = false
    @State private var showsConfirmation = false
    @State private var errorMessage: String?

    private let engine = BundledMoleBridge()
    private let historyStore = CleanupHistoryStore.shared

    private var title: String {
        tool == .developer ? String(localized: "开发缓存") : String(localized: "安装包")
    }
    private var selected: [Candidate] { candidates.filter(\.isSelected) }
    private var selectedSize: Int64 { selected.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("固定范围扫描 · 所有选中项进入废纸篓")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }.disabled(isApplying)
            }
            .padding(24)
            Divider()
            content
            Divider()
            HStack {
                Text("已选择 \(selected.count) 项 · \(ByteFormatting.string(selectedSize))")
                    .font(.headline)
                Spacer()
                if isApplying { ProgressView().controlSize(.small) }
                Button("移入废纸篓") { showsConfirmation = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading || isApplying || selected.isEmpty || header == nil)
            }
            .padding(20)
            .background(.bar)
        }
        .frame(minWidth: 700, minHeight: 520)
        .task { await load() }
        .confirmationDialog("确认处理选中项目？", isPresented: $showsConfirmation) {
            Button("移入废纸篓", role: .destructive) { apply() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("\(selected.count) 项，共 \(ByteFormatting.string(selectedSize))")
        }
        .alert("操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? String(localized: "未知错误")) }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("正在生成工具计划…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if candidates.isEmpty {
            ContentUnavailableView("没有发现候选项", systemImage: "checkmark.circle", description: Text("当前范围不需要处理。"))
        } else {
            List($candidates) { $candidate in
                HStack(spacing: 12) {
                    Toggle("", isOn: $candidate.isSelected).labelsHidden()
                    Image(systemName: tool == .developer ? "hammer" : "shippingbox")
                        .foregroundStyle(candidate.risk == "safe" ? SpruceTheme.accent : .orange)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(candidate.name).font(.body.weight(.medium))
                        Text(candidate.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(candidate.risk == "safe" ? String(localized: "可重建") : String(localized: "需确认"))
                        .font(.caption)
                        .foregroundStyle(candidate.risk == "safe" ? SpruceTheme.accent : .orange)
                    Text(ByteFormatting.string(candidate.size)).monospacedDigit()
                }
                .padding(.vertical, 6)
            }
            .listStyle(.inset)
        }
    }

    @MainActor
    private func load() async {
        do {
            let events = try await engine.toolPlanEvents(tool: tool)
            header = events.compactMap { event -> EnginePlanHeader? in
                guard case let .started(value) = event else { return nil }
                return value
            }.first
            candidates = events.compactMap { event in
                guard case let .uninstallCandidate(value) = event else { return nil }
                return Candidate(
                    id: value.id,
                    name: value.name,
                    path: value.path,
                    size: value.size,
                    risk: value.risk,
                    isSelected: value.defaultSelected
                )
            }
        } catch {
            errorMessage = String(localized: "无法生成工具计划。")
        }
        isLoading = false
    }

    private func apply() {
        guard let planID = header?.planID else { return }
        isApplying = true
        Task {
            do {
                let events = try await engine.applyPlanEvents(planID: planID, candidateIDs: selected.map(\.id))
                let record = CleanupHistoryRecord.make(
                    operation: .toolbox,
                    planID: planID,
                    selectedCount: selected.count,
                    events: events
                )
                try? await historyStore.append(record)
                isApplying = false
                dismiss()
            } catch {
                isApplying = false
                errorMessage = String(localized: "计划已变化、已失效或无法访问废纸篓。")
            }
        }
    }
}
