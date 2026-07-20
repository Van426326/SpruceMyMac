// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

struct SystemMaintenanceCommand: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let command: String
    let requiresReview: Bool

    static let all: [SystemMaintenanceCommand] = [
        SystemMaintenanceCommand(
            id: "flush-dns-cache",
            title: String(localized: "刷新 DNS 缓存"),
            detail: String(localized: "清空系统 DNS 缓存并让 mDNSResponder 重新加载；不会修改网络设置。"),
            symbol: "network",
            command: "sudo /usr/bin/dscacheutil -flushcache\nsudo /usr/bin/killall -HUP mDNSResponder",
            requiresReview: false
        ),
        SystemMaintenanceCommand(
            id: "rebuild-spotlight-index",
            title: String(localized: "重建 Spotlight 索引"),
            detail: String(localized: "要求 Spotlight 重建启动磁盘索引；完成前可能产生较高磁盘活动。"),
            symbol: "magnifyingglass.circle",
            command: "sudo /usr/bin/mdutil -E /",
            requiresReview: true
        )
    ]
}

struct SystemMaintenanceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copiedCommandID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 18) {
                    safetyNotice
                    ForEach(SystemMaintenanceCommand.all) { command in
                        commandCard(command)
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 760, minHeight: 620)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("系统命令助手")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("显示经过审计的固定命令，由你在 Terminal 中检查并执行。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("关闭") { dismiss() }
        }
        .padding(24)
    }

    private var safetyNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "SpruceMyMac 不执行 sudo 命令，也不会读取管理员密码。复制后请在 Terminal 中检查并手动运行。",
                systemImage: "lock.shield"
            )
            .font(.headline)
            Text("这些命令由 macOS 提供；执行时 Terminal 会请求管理员认证。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(SpruceTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
    }

    private func commandCard(_ command: SystemMaintenanceCommand) -> some View {
        let color: Color = command.requiresReview ? .orange : SpruceTheme.accent

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: command.symbol)
                    .font(.title2)
                    .foregroundStyle(color)
                    .frame(width: 46, height: 46)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(command.title).font(.headline)
                        Text(command.requiresReview ? String(localized: "需确认") : String(localized: "低风险"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(color)
                    }
                    Text(command.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Text(verbatim: command.command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Label("固定命令，不包含用户输入或动态路径。", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("打开 Terminal") { openTerminal() }
                Button {
                    copy(command)
                } label: {
                    Label(
                        copiedCommandID == command.id
                            ? String(localized: "已复制")
                            : String(localized: "复制命令"),
                        systemImage: copiedCommandID == command.id ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .cardSurface()
    }

    private func copy(_ command: SystemMaintenanceCommand) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command.command, forType: .string)
        copiedCommandID = command.id
    }

    private func openTerminal() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }
}
