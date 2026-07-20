// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

struct OperationHistoryView: View {
    @State private var records: [CleanupHistoryRecord] = []
    @State private var confirmsClear = false
    private let store = CleanupHistoryStore.shared

    var body: some View {
        List {
            if records.isEmpty {
                ContentUnavailableView("尚无操作记录", systemImage: "clock.arrow.circlepath")
            } else {
                ForEach(records) { record in
                    HStack(spacing: 13) {
                        Image(systemName: icon(for: record.operation))
                            .font(.title3)
                            .foregroundStyle(color(for: record.outcome))
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title(for: record.operation)).font(.body.weight(.medium))
                            Text(record.finishedAt, format: .dateTime.year().month().day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(ByteFormatting.string(record.freedBytes)).monospacedDigit().fontWeight(.medium)
                            Text("成功 \(record.succeededCount) · 失败 \(record.failedCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("最多保留最近 200 条本地记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清空历史", role: .destructive) { confirmsClear = true }
                    .disabled(records.isEmpty)
            }
            .padding(16)
            .background(.bar)
        }
        .task { await reload() }
        .confirmationDialog("清空全部操作历史？", isPresented: $confirmsClear) {
            Button("清空", role: .destructive) {
                Task {
                    try? await store.removeAll()
                    await reload()
                }
            }
            Button("取消", role: .cancel) { }
        }
    }

    @MainActor
    private func reload() async { records = await store.records() }

    private func title(for operation: CleanupHistoryRecord.Operation) -> String {
        switch operation {
        case .cleanup: String(localized: "智能清理")
        case .uninstall: String(localized: "应用卸载")
        case .analyzer: String(localized: "空间分析")
        case .toolbox: String(localized: "工具箱")
        case .maintenance: String(localized: "系统维护")
        }
    }

    private func icon(for operation: CleanupHistoryRecord.Operation) -> String {
        switch operation {
        case .cleanup: "leaf"
        case .uninstall: "square.grid.2x2"
        case .analyzer: "chart.pie"
        case .toolbox: "wrench.and.screwdriver"
        case .maintenance: "checkmark.shield"
        }
    }

    private func color(for outcome: CleanupHistoryRecord.Outcome) -> Color {
        switch outcome {
        case .completed: SpruceTheme.accent
        case .partial: .orange
        case .failed: .red
        }
    }
}
