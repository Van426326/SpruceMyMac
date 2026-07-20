// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                storageHero
                metricGrid
                safetyNote
            }
            .padding(32)
            .frame(maxWidth: 1080, alignment: .leading)
        }
        .task {
            await model.refreshSystemSnapshot()
        }
        .refreshable {
            await model.refreshSystemSnapshot()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("早上好")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("先看清空间去向，再决定清理什么。")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.refreshSystemSnapshot() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshingSystemSnapshot)
        }
    }

    private var storageHero: some View {
        HStack(spacing: 34) {
            ZStack {
                Circle()
                    .stroke(SpruceTheme.accentSoft, lineWidth: 17)
                Circle()
                    .trim(from: 0, to: model.systemSnapshot.storageUsageFraction)
                    .stroke(
                        SpruceTheme.accent.gradient,
                        style: StrokeStyle(lineWidth: 17, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 4) {
                    Text(model.systemSnapshot.storageUsageFraction, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("已使用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 158, height: 158)
            .accessibilityLabel("磁盘已使用")
            .accessibilityValue("\(Int(model.systemSnapshot.storageUsageFraction * 100))%")

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Macintosh HD")
                        .font(.title2.weight(.semibold))
                    Text("可用 \(ByteFormatting.string(model.systemSnapshot.storageAvailable))，共 \(ByteFormatting.string(model.systemSnapshot.storageTotal))")
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack(spacing: 28) {
                    StorageLegend(color: SpruceTheme.accent, title: String(localized: "已使用"), value: model.systemSnapshot.storageUsed)
                    StorageLegend(color: SpruceTheme.accentSoft, title: String(localized: "可用"), value: model.systemSnapshot.storageAvailable)
                }

                Button {
                    model.selectedSection = .cleanup
                } label: {
                    Label("开始智能扫描", systemImage: "sparkle.magnifyingglass")
                        .font(.headline)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            Spacer(minLength: 0)
        }
        .cardSurface()
    }

    private var metricGrid: some View {
        HStack(spacing: 16) {
            MetricCard(
                title: String(localized: "内存"),
                value: ByteFormatting.string(model.systemSnapshot.memoryUsed),
                detail: String(localized: "共 \(ByteFormatting.string(model.systemSnapshot.memoryTotal))"),
                fraction: model.systemSnapshot.memoryUsageFraction,
                symbol: "memorychip"
            )
            MetricCard(
                title: String(localized: "清理引擎"),
                value: String(localized: "安全计划"),
                detail: String(localized: "确认后移入废纸篓"),
                fraction: nil,
                symbol: "checkmark.shield"
            )
            MetricCard(
                title: String(localized: "上次扫描"),
                value: model.systemSnapshot == .empty ? String(localized: "尚未扫描") : String(localized: "刚刚"),
                detail: String(localized: "系统状态已更新"),
                fraction: nil,
                symbol: "clock.arrow.circlepath"
            )
        }
    }

    private var safetyNote: some View {
        Label {
            Text("SpruceMyMac 会先生成一次性计划；只有确认并再次通过路径与文件指纹校验后，选中项目才会进入废纸篓。")
        } icon: {
            Image(systemName: "lock.shield")
                .foregroundStyle(SpruceTheme.accent)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}

private struct StorageLegend: View {
    let color: Color
    let title: String
    let value: Int64

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(ByteFormatting.string(value)).font(.headline)
            }
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let fraction: Double?
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(SpruceTheme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Text(value).font(.title3.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let fraction {
                ProgressView(value: fraction)
                    .tint(SpruceTheme.accent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
        .cardSurface()
    }
}
