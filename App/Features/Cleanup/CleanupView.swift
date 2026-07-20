// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

struct CleanupView: View {
    private enum ScanState: Equatable {
        case idle
        case scanning
        case finished(skipped: Int)
        case failed(message: String)
    }

    @State private var candidates: [CleanupCandidate] = []
    @State private var scanState: ScanState = .idle
    @State private var scanTask: Task<Void, Never>?
    @State private var presentedPlan: CleanupPlan?
    @State private var enginePlanHeader: EnginePlanHeader?
    private let scanner = UserCacheScanner()
    private let engine = BundledMoleBridge()

    private var selectedSize: Int64 {
        candidates.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if !candidates.isEmpty {
                selectionBar
            }
        }
        .onDisappear {
            scanTask?.cancel()
        }
        .sheet(item: $presentedPlan) { plan in
            CleanupPlanPreviewView(plan: plan) {
                candidates = []
                enginePlanHeader = nil
                scanState = .idle
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("智能清理")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("扫描用户缓存并生成只读预览，不会自动删除。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if scanState == .scanning {
                Button("停止扫描") {
                    scanTask?.cancel()
                    scanState = .idle
                }
            } else {
                Button {
                    startScan()
                } label: {
                    Label(
                        candidates.isEmpty ? String(localized: "开始扫描") : String(localized: "重新扫描"),
                        systemImage: "sparkle.magnifyingglass"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(28)
    }

    @ViewBuilder
    private var content: some View {
        switch scanState {
        case .idle where candidates.isEmpty:
            ContentUnavailableView {
                Label("准备安全扫描", systemImage: "leaf.circle")
            } description: {
                Text("扫描 ~/Library/Caches，确认后仅移入废纸篓。")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .scanning:
            VStack(spacing: 15) {
                ProgressView().controlSize(.large)
                Text("正在统计缓存大小…").font(.headline)
                Text("你可以随时停止，扫描在后台进行。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("扫描失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { startScan() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            candidateList
        }
    }

    private var candidateList: some View {
        List {
            Section {
                ForEach($candidates) { $candidate in
                    HStack(spacing: 13) {
                        Toggle("", isOn: $candidate.isSelected)
                            .labelsHidden()
                        Image(systemName: "shippingbox")
                            .font(.title3)
                            .foregroundStyle(SpruceTheme.accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(candidate.name)
                                .font(.body.weight(.medium))
                            Text(candidate.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(candidate.risk.title)
                            .font(.caption)
                            .foregroundStyle(SpruceTheme.accent)
                        Text(ByteFormatting.string(candidate.size))
                            .font(.body.monospacedDigit().weight(.medium))
                            .frame(width: 90, alignment: .trailing)
                    }
                    .padding(.vertical, 7)
                }
            } header: {
                HStack {
                    Text("应用缓存")
                    Spacer()
                    Text("\(candidates.count) 项")
                }
            } footer: {
                if case let .finished(skipped) = scanState, skipped > 0 {
                    Text("有 \(skipped) 项因权限或读取错误未能统计。")
                }
            }
        }
        .listStyle(.inset)
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Button(
                candidates.allSatisfy(\.isSelected) ? String(localized: "取消全选") : String(localized: "全选")
            ) {
                let newValue = !candidates.allSatisfy(\.isSelected)
                for index in candidates.indices {
                    candidates[index].isSelected = newValue
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("已选择 \(ByteFormatting.string(selectedSize))")
                    .font(.headline)
                Text("执行前将再次校验计划")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("预览清理计划") {
                let selected = candidates.filter(\.isSelected)
                presentedPlan = CleanupPlan(
                    candidates: selected,
                    enginePlanID: enginePlanHeader?.planID,
                    engineExpiresAt: enginePlanHeader?.expiresAt
                )
            }
                .buttonStyle(.borderedProminent)
                .disabled(selectedSize == 0)
                .help("查看路径、风险和计划有效期")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private func startScan() {
        scanTask?.cancel()
        candidates = []
        enginePlanHeader = nil
        scanState = .scanning
        scanTask = Task {
            do {
                if await engine.isAvailable() {
                    let events = try await engine.cleanPlanEvents()
                    guard !Task.isCancelled else { return }
                    enginePlanHeader = events.compactMap { event -> EnginePlanHeader? in
                        guard case let .started(header) = event else { return nil }
                        return header
                    }.first
                    candidates = candidates(from: events)
                    scanState = .finished(skipped: 0)
                } else {
                    let result = await scanner.scan()
                    guard !Task.isCancelled else { return }
                    candidates = result.candidates
                    scanState = .finished(skipped: result.skippedItemCount)
                }
            } catch {
                guard !Task.isCancelled else { return }
                scanState = .failed(message: String(localized: "引擎未能生成有效计划，请检查日志后重试。"))
            }
        }
    }

    private func candidates(from events: [EngineEvent]) -> [CleanupCandidate] {
        events.compactMap { event in
            guard case let .candidate(candidate) = event,
                  let path = candidate.path,
                  let device = candidate.device,
                  let inode = candidate.inode,
                  let modifiedAt = candidate.modifiedAt else {
                return nil
            }

            return CleanupCandidate(
                id: candidate.id,
                name: candidate.name ?? URL(fileURLWithPath: path).lastPathComponent,
                path: path,
                size: candidate.size,
                category: .applicationCache,
                risk: candidate.risk == "review" ? .review : .safe,
                fingerprint: FileFingerprint(device: device, inode: inode, modifiedAt: modifiedAt),
                isSelected: false
            )
        }
    }
}
