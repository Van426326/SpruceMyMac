// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

@MainActor
struct SettingsView: View {
    @StateObject private var engineUpdates: EngineUpdateViewModel

    init(engineUpdates: EngineUpdateViewModel = EngineUpdateViewModel()) {
        _engineUpdates = StateObject(wrappedValue: engineUpdates)
    }

    var body: some View {
        TabView {
            GeneralSettingsView(engineUpdates: engineUpdates)
                .tabItem { Label("通用", systemImage: "gearshape") }
            AboutView()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 620, height: 570)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage("showAdvancedItems") private var showAdvancedItems = false
    @ObservedObject var engineUpdates: EngineUpdateViewModel

    var body: some View {
        Form {
            Section {
                Toggle("显示高级候选项", isOn: $showAdvancedItems)
                LabeledContent("清理方式", value: String(localized: "确认后移入废纸篓"))
                LabeledContent("数据目录", value: "Application Support/SpruceMyMac")
            }

            Section("清理引擎") {
                if let current = engineUpdates.currentEngine {
                    LabeledContent("引擎版本", value: current.version.description)
                    LabeledContent("Mole 提交", value: String(current.upstreamCommit.prefix(10)))
                    if let provenance = engineUpdates.provenanceDescription {
                        LabeledContent("引擎来源", value: provenance)
                    }
                    if let sourceURL = current.sourceURL {
                        Link("查看对应源码", destination: sourceURL)
                    }
                } else if engineUpdates.phase != .refreshing {
                    Text("尚未读取引擎状态。")
                        .foregroundStyle(.secondary)
                }

                if !engineUpdates.updatesEnabled {
                    Label(
                        "引擎更新尚未配置；当前将继续使用已验证的本地引擎。",
                        systemImage: "lock.shield"
                    )
                    .foregroundStyle(.secondary)
                }

                Text("仅接受由 SpruceMyMac 官方密钥签名且与当前应用兼容的引擎包。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let candidate = engineUpdates.candidate {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("发现版本 \(candidate.manifest.engineVersion.description)")
                            .font(.callout.weight(.semibold))
                        LabeledContent("Mole 提交", value: String(candidate.manifest.upstreamCommit.prefix(10)))
                        LabeledContent("发布时间", value: candidate.manifest.publishedAt)
                        Link("查看更新对应源码", destination: candidate.manifest.source.url)
                        Button("下载、验证并安装") {
                            Task { await engineUpdates.installCandidate() }
                        }
                        .disabled(engineUpdates.isBusy)
                    }
                }

                if let phaseMessage = engineUpdates.phaseMessage {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(phaseMessage)
                    }
                    .accessibilityElement(children: .combine)
                }

                HStack {
                    Button("刷新引擎状态") {
                        Task { await engineUpdates.refreshCurrent() }
                    }
                    .disabled(engineUpdates.isBusy)

                    Button("检查引擎更新") {
                        Task { await engineUpdates.checkForUpdate() }
                    }
                    .disabled(engineUpdates.isBusy || !engineUpdates.updatesEnabled)

                    if engineUpdates.canRestoreBundled {
                        Button("恢复内置引擎") {
                            Task { await engineUpdates.restoreBundled() }
                        }
                        .disabled(engineUpdates.isBusy)
                    }
                }

                if let notice = engineUpdates.noticeMessage {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = engineUpdates.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel(String(localized: "引擎更新错误：\(error)"))
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .task {
            if engineUpdates.currentEngine == nil {
                await engineUpdates.refreshCurrent()
            }
        }
    }
}

private enum BundledLegalDocument: String, Identifiable {
    case license = "LICENSE"
    case notices = "THIRD_PARTY_NOTICES"

    var id: Self { self }
    var title: String {
        self == .license ? String(localized: "GPL-3.0 许可证") : String(localized: "第三方声明")
    }
    var fileExtension: String? { self == .license ? nil : "md" }
}

private struct AboutView: View {
    @State private var legalDocument: BundledLegalDocument?

    private var version: String {
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return String(localized: "版本 \(marketing)（\(build)）")
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 88, height: 88)
            VStack(spacing: 4) {
                Text("SpruceMyMac")
                    .font(.title2.weight(.bold))
                Text(version)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("独立开发的 GPL-3.0 开源 macOS 清理与空间分析工具，底层清理能力基于固定版本的 tw93/Mole。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 430)
            Text("本项目与 Apple、Mole 项目及 Mole for Mac 无隶属或背书关系。")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack(spacing: 12) {
                Link("项目主页", destination: URL(string: "https://github.com/Van426326/SpruceMyMac")!)
                Link("Mole 上游", destination: URL(string: "https://github.com/tw93/Mole")!)
            }
            HStack(spacing: 12) {
                Button("查看许可证") { legalDocument = .license }
                Button("第三方声明") { legalDocument = .notices }
            }
        }
        .padding(24)
        .sheet(item: $legalDocument) { document in
            LegalDocumentView(document: document)
        }
    }
}

private struct LegalDocumentView: View {
    let document: BundledLegalDocument
    @Environment(\.dismiss) private var dismiss

    private var content: String {
        guard let url = Bundle.main.url(
            forResource: document.rawValue,
            withExtension: document.fileExtension
        ) else {
            return String(localized: "未能读取随应用分发的文档。")
        }
        return (try? String(contentsOf: url, encoding: .utf8))
            ?? String(localized: "未能读取随应用分发的文档。")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(document.title).font(.title3.weight(.semibold))
                Spacer()
                Button("关闭") { dismiss() }
            }
            .padding(18)
            Divider()
            ScrollView {
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}
