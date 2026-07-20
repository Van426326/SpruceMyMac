// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SpaceAnalyzerView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all
        case largest
        case old
        case installers

        var id: Self { self }
        var title: String {
            switch self {
            case .all: String(localized: "全部")
            case .largest: String(localized: "最大文件")
            case .old: String(localized: "一年未修改")
            case .installers: String(localized: "安装包")
            }
        }
    }

    @State private var rootURL: URL?
    @State private var files: [AnalyzedFile] = []
    @State private var filter = Filter.all
    @State private var isChoosingFolder = false
    @State private var isScanning = false
    @State private var scannedFileCount = 0
    @State private var scannedBytes: Int64 = 0
    @State private var scanTask: Task<Void, Never>?
    @State private var trashTarget: AnalyzedFile?
    @State private var errorMessage: String?

    private let analyzer = SpaceAnalyzer()
    private let trashService = AnalyzerTrashService()
    private let historyStore = CleanupHistoryStore.shared

    private var visibleFiles: [AnalyzedFile] {
        let filtered = files.filter { file in
            switch filter {
            case .all, .largest: true
            case .old: file.isOld
            case .installers: file.isInstaller
            }
        }
        let sorted = filtered.sorted { $0.size > $1.size }
        return filter == .largest ? Array(sorted.prefix(50)) : sorted
    }

    private var categoryTotals: [(AnalyzedFile.Category, Int64)] {
        AnalyzedFile.Category.allCases.compactMap { category in
            let total = files.filter { $0.category == category }.reduce(0) { $0 + $1.size }
            return total > 0 ? (category, total) : nil
        }
        .sorted { $0.1 > $1.1 }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if rootURL == nil {
                emptyState
            } else {
                results
            }
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                startScan(url)
            }
        }
        .confirmationDialog(
            "移入废纸篓？",
            isPresented: Binding(
                get: { trashTarget != nil },
                set: { if !$0 { trashTarget = nil } }
            )
        ) {
            Button("移入废纸篓", role: .destructive) {
                if let target = trashTarget { moveToTrash(target) }
            }
            Button("取消", role: .cancel) { trashTarget = nil }
        } message: {
            Text(trashTarget?.path ?? "")
        }
        .onDisappear { scanTask?.cancel() }
        .alert("操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? String(localized: "未知错误"))
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("空间分析")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(rootURL?.path ?? String(localized: "选择目录后渐进显示大文件，扫描期间也可查看结果。"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if isScanning {
                Button("停止") {
                    scanTask?.cancel()
                    isScanning = false
                }
            }
            Button {
                isChoosingFolder = true
            } label: {
                Label(
                    rootURL == nil ? String(localized: "选择文件夹") : String(localized: "更换文件夹"),
                    systemImage: "folder.badge.plus"
                )
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(28)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("选择要分析的文件夹", systemImage: "chart.pie")
        } description: {
            Text("不会在启动时自动扫描磁盘。仅统计你选择目录中的普通文件。")
        } actions: {
            Button("选择文件夹") { isChoosingFolder = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var results: some View {
        VStack(spacing: 0) {
            summary
            HStack {
                Picker("筛选", selection: $filter) {
                    ForEach(Filter.allCases) { item in Text(item.title).tag(item) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 480)
                Spacer()
                Text("发现 \(files.count) 个大文件")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            List(visibleFiles) { file in
                fileRow(file)
                    .padding(.vertical, 6)
            }
            .listStyle(.inset)
        }
    }

    private var summary: some View {
        VStack(spacing: 14) {
            HStack {
                MetricLabel(title: String(localized: "已扫描"), value: String(localized: "\(scannedFileCount) 个文件"), symbol: "doc.text.magnifyingglass")
                MetricLabel(title: String(localized: "已遍历容量"), value: ByteFormatting.string(scannedBytes), symbol: "internaldrive")
                MetricLabel(title: String(localized: "大文件合计"), value: ByteFormatting.string(files.reduce(0) { $0 + $1.size }), symbol: "arrow.up.right.square")
                if isScanning { ProgressView().controlSize(.small) }
            }
            if !categoryTotals.isEmpty {
                GeometryReader { geometry in
                    HStack(spacing: 3) {
                        ForEach(categoryTotals, id: \.0) { category, size in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(color(for: category))
                                .frame(width: max(6, geometry.size.width * CGFloat(size) / CGFloat(max(1, files.reduce(0) { $0 + $1.size }))))
                                .help("\(category.title) · \(ByteFormatting.string(size))")
                        }
                    }
                }
                .frame(height: 12)
            }
        }
        .padding(20)
        .cardSurface()
        .padding(24)
    }

    private func fileRow(_ file: AnalyzedFile) -> some View {
        HStack(spacing: 13) {
            Image(systemName: file.category.systemImage)
                .font(.title3)
                .foregroundStyle(color(for: file.category))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).font(.body.weight(.medium))
                Text(file.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(ByteFormatting.string(file.size)).monospacedDigit().fontWeight(.medium)
                Text(file.modifiedAt, format: .dateTime.year().month().day())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button { QuickLookPresenter.shared.preview(file.url) } label: {
                Image(systemName: "eye")
            }
            .buttonStyle(.borderless)
            .help("快速查看")
            Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示")
            Button(role: .destructive) { trashTarget = file } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("移入废纸篓")
        }
    }

    private func startScan(_ root: URL) {
        scanTask?.cancel()
        rootURL = root
        files = []
        scannedFileCount = 0
        scannedBytes = 0
        errorMessage = nil
        isScanning = true
        scanTask = Task {
            for await progress in await analyzer.scan(root: root) {
                guard !Task.isCancelled else { return }
                scannedFileCount = progress.scannedFileCount
                scannedBytes = progress.scannedBytes
                if let candidate = progress.candidate,
                   !files.contains(where: { $0.id == candidate.id }) {
                    files.append(candidate)
                }
            }
            isScanning = false
        }
    }

    private func moveToTrash(_ file: AnalyzedFile) {
        guard let rootURL else { return }
        Task {
            do {
                try await trashService.moveToTrash(file, under: rootURL)
                files.removeAll { $0.id == file.id }
                let record = CleanupHistoryRecord(
                    id: UUID(),
                    operation: .analyzer,
                    planID: "analyzer-\(file.id)",
                    finishedAt: Date(),
                    selectedCount: 1,
                    succeededCount: 1,
                    failedCount: 0,
                    freedBytes: file.size,
                    outcome: .completed
                )
                try? await historyStore.append(record)
            } catch {
                errorMessage = String(localized: "文件已经变化或无法移入废纸篓。")
            }
            trashTarget = nil
        }
    }

    private func color(for category: AnalyzedFile.Category) -> Color {
        switch category {
        case .video: .purple
        case .archive: .blue
        case .installer: .orange
        case .document: SpruceTheme.accent
        case .other: .gray
        }
    }
}

private struct MetricLabel: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).foregroundStyle(SpruceTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.headline).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
