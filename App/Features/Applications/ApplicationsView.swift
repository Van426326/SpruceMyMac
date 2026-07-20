// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

struct ApplicationsView: View {
    private enum SortOrder: String, CaseIterable, Identifiable {
        case size
        case name
        case recentlyUsed

        var id: Self { self }
        var title: String {
            switch self {
            case .size: String(localized: "按大小")
            case .name: String(localized: "按名称")
            case .recentlyUsed: String(localized: "最近使用")
            }
        }
    }

    @State private var applications: [InstalledApplication] = []
    @State private var searchText = ""
    @State private var sortOrder = SortOrder.size
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var uninstallTarget: InstalledApplication?

    private let engine = BundledMoleBridge()

    private var visibleApplications: [InstalledApplication] {
        let filtered = applications.filter {
            searchText.isEmpty
                || $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.bundleID.localizedCaseInsensitiveContains(searchText)
        }
        return filtered.sorted {
            switch sortOrder {
            case .size:
                $0.size == $1.size ? $0.name < $1.name : $0.size > $1.size
            case .name:
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            case .recentlyUsed:
                ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task { await loadApplications() }
        .sheet(item: $uninstallTarget) { application in
            ApplicationUninstallView(application: application) {
                uninstallTarget = nil
                Task { await loadApplications() }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("应用卸载")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("查看应用与精确关联残留，所有移除操作默认进入废纸篓。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await loadApplications() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }

            HStack {
                TextField("搜索应用或 Bundle ID", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 380)
                Spacer()
                Picker("排序", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.menu)
                Text("\(visibleApplications.count) 个应用")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && applications.isEmpty {
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("正在读取应用信息…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, applications.isEmpty {
            ContentUnavailableView {
                Label("无法读取应用", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("重试") { Task { await loadApplications() } }
            }
        } else {
            List(visibleApplications) { application in
                applicationRow(application)
                    .padding(.vertical, 7)
            }
            .listStyle(.inset)
        }
    }

    private func applicationRow(_ application: InstalledApplication) -> some View {
        HStack(spacing: 14) {
            Image(nsImage: application.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(application.name).font(.body.weight(.semibold))
                    if application.isProtected {
                        Label("受保护", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(application.bundleID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(application.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(ByteFormatting.string(application.size))
                    .font(.body.monospacedDigit().weight(.medium))
                Text(application.sourceTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let lastUsedAt = application.lastUsedAt {
                    Text(lastUsedAt, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 120, alignment: .trailing)
            Button(application.isProtected ? String(localized: "已锁定") : String(localized: "查看残留")) {
                uninstallTarget = application
            }
            .disabled(application.isProtected)
            .frame(width: 88)
        }
    }

    @MainActor
    private func loadApplications() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let events = try await engine.applicationListEvents()
            applications = events.compactMap { event in
                guard case let .application(application) = event else { return nil }
                return InstalledApplication(application)
            }
        } catch {
            errorMessage = String(localized: "内置引擎未能生成应用清单。")
        }
    }
}
