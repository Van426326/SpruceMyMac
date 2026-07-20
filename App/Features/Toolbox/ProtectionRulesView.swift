// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import UniformTypeIdentifiers

struct ProtectionRulesView: View {
    @State private var rules: [ProtectionRule] = []
    @State private var isChoosingItem = false
    @State private var errorMessage: String?
    private let store = ProtectionRuleStore.shared

    var body: some View {
        List {
            Section("自定义白名单") {
                if rules.isEmpty {
                    Text("尚未添加自定义路径")
                        .foregroundStyle(.secondary)
                }
                ForEach(rules) { rule in
                    HStack {
                        Image(systemName: "checkmark.shield.fill").foregroundStyle(SpruceTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name).font(.body.weight(.medium))
                            Text(rule.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task {
                                try? await store.remove(rule)
                                await reload()
                            }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 5)
                }
                Button {
                    isChoosingItem = true
                } label: {
                    Label("添加文件或文件夹", systemImage: "plus")
                }
            }

            Section {
                ForEach(ProtectionRuleStore.builtInRules, id: \.self) { rule in
                    Label(rule, systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("内置保护规则")
            } footer: {
                Text("白名单在扫描、计划生成和执行前都会检查；添加规则不会自动恢复已处理项目。")
            }
        }
        .listStyle(.inset)
        .task { await reload() }
        .fileImporter(isPresented: $isChoosingItem, allowedContentTypes: [.item]) { result in
            guard case let .success(url) = result else { return }
            Task {
                do {
                    try await store.add(url)
                    await reload()
                } catch {
                    errorMessage = String(localized: "无法添加根目录、符号链接或无效路径。")
                }
            }
        }
        .alert("无法添加规则", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? String(localized: "未知错误")) }
    }

    @MainActor
    private func reload() async {
        rules = await store.rules()
    }
}
