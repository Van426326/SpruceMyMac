# SpruceMyMac

[English](README.md) | 简体中文

SpruceMyMac 是一款独立、开源的 macOS 清理与存储空间检查应用。应用使用 SwiftUI 构建，并通过版本化的结构化桥接协议调用 [tw93/Mole](https://github.com/tw93/Mole) 的清理能力。

当前版本提供原生应用界面、实时磁盘与内存指标、不可变清理计划、可恢复的废纸篓清理、应用卸载、渐进式空间分析、固定范围工具、操作历史、用户保护规则，以及用于执行固定系统维护命令的助手。内置 Engine 基于固定的 Mole revision，并通过版本化 NDJSON 协议与 App 通信。

## 系统要求

- 运行应用：macOS 14 或更高版本
- 从源码构建：Xcode 16 或更高版本，以及
  [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## 下载与安装

当前版本是
[SpruceMyMac 0.2.1](https://github.com/Van426326/SpruceMyMac/releases/tag/v0.2.1)。
也可以通过稳定的
[最新版下载链接](https://github.com/Van426326/SpruceMyMac/releases/latest)
下载 `SpruceMyMac.dmg`。

当前社区构建未进行 Apple Developer ID 签名，支持 Apple 芯片和 Intel Mac：

1. 下载 `SpruceMyMac.dmg`；如需校验，同时下载 `SpruceMyMac.dmg.sha256`。
2. 如果下载了两个文件，可在终端中校验 DMG：

   ```bash
   shasum -a 256 -c SpruceMyMac.dmg.sha256
   ```

3. 打开 DMG，将 `SpruceMyMac.app` 拖入 `/Applications`。
4. 首次启动时，按住 Control 点击应用，选择“打开”并确认。如果 macOS 仍然阻止启动，请进入“系统设置 → 隐私与安全性”，找到 SpruceMyMac 后选择“仍要打开”。

每个 DMG 旁都会同时发布 SHA-256 校验文件和完整的 GPL 对应源码归档。

### 从 0.1.0 升级

SpruceMyMac 从 0.2.0 开始支持手动更新 Engine。0.1.0 用户必须先从 GitHub Releases 手动下载并安装一次 0.2.0 或更高版本；Engine 更新器只更新清理 Engine，不能替换或升级 App 本身。直接使用当前版本覆盖现有 App 即可，安装前不需要先更新 Engine。

## 从源码构建

```bash
xcodegen generate
xcodebuild -project SpruceMyMac.xcodeproj -scheme SpruceMyMac -configuration Debug -derivedDataPath build build CODE_SIGNING_ALLOWED=NO
```

未签名构建适合本地使用和 GitHub 社区分发。由于构建未经过 notarization，用户可能需要右键应用并选择“打开”。

运行全部检查并创建未签名的 Universal 2 验证构建：

```bash
Scripts/verify-localization.sh
xcodebuild -quiet -project SpruceMyMac.xcodeproj -scheme SpruceMyMac -configuration Debug -derivedDataPath build/TestDerivedData test CODE_SIGNING_ALLOWED=NO
Scripts/build-release.sh --unsigned --output build/validation-release
```

Developer ID 签名、DMG 创建、notarization 和对应源码打包流程记录在 [`docs/RELEASE.md`](docs/RELEASE.md) 中。

## 项目状态

第一阶段实现已经完成并具备发布条件。破坏性操作不会自动执行：用户必须先检查候选项并确认操作，Engine 才会把选中的项目移动到 macOS 废纸篓。如果计划已过期、超出对应命令允许的目录、被重复使用、命中保护规则，或文件系统身份与计划生成时不再一致，计划会被拒绝。

界面源语言为简体中文，每个随应用发布的字符串都提供英文 fallback。应用图标源文件位于 [`Brand/SpruceMyMac-AppIcon.svg`](Brand/SpruceMyMac-AppIcon.svg)。

## 准备 Mole Engine

仓库记录可重现的 Mole 输入，而不是跟踪未经审查、持续变化的分支：

```bash
git submodule update --init --recursive
Scripts/prepare-engine.sh Vendor/Mole build/Engine/Mole
Engine/Tests/gui_plan_test.sh build/Engine/Mole
```

开发时，可在 Xcode scheme 中把 `SPRUCE_ENGINE_PATH` 设置为准备好的 `build/Engine/Mole/bin/gui.sh`。如果找不到准备好的 Engine，应用会使用本地只读扫描器。发布打包过程会把完整 Engine 复制到 `SpruceMyMac.app/Contents/Resources/Engine/Mole`。

当前实现的内部命令包括：

```bash
gui.sh clean-plan --format ndjson --no-auth
gui.sh app-list --format ndjson --no-auth
gui.sh uninstall-plan --inventory-id <id> --app-id <id> --format ndjson --no-auth
gui.sh tool-plan --tool developer --format ndjson --no-auth
gui.sh apply-plan --plan-id <id> --items <id,id> --format ndjson --no-auth
```

所有 apply 操作只接受不透明的候选项 ID；移动任何内容前都会重新验证完整选择，计划会被原子消费以防止重放，删除操作统一通过 Mole 的废纸篓删除通道执行。

## 手动更新 Engine

手动更新 Engine 需要 SpruceMyMac 0.2.0 或更高版本。用户可以在设置窗口中查看当前 Engine，并点击“检查更新”。应用不会在后台自动安装 Engine；用户需要主动检查、确认并安装可用更新。

只有满足以下条件的下载 Engine 才会被接受：App 内置的 SpruceMyMac Ed25519 公钥成功验证签名 manifest；每个 payload 文件都与 manifest 完全一致；Engine 报告的协议版本和 App build 兼容范围与当前 App 匹配。active 和 previous 版本保存在 `~/Library/Application Support/SpruceMyMac/Engines`；App bundle 中不可变的内置 Engine 始终作为最终回退。设置中也提供恢复内置 Engine 的操作。

SpruceMyMac 0.2.1 内置 Engine 1.0.1，公开 Engine Feed 同样指向 Engine 1.0.1。因此，全新安装的 0.2.1 当前会显示 Engine 已是最新版本。以后发布版本更高且兼容的 Engine 后，用户可以直接在设置中安装，无需重新下载整个 App。

仓库中不提交任何签名密钥。未设置 `ENGINE_SIGNING_PUBLIC_KEY` 的构建会安全禁用“检查更新”按钮，忽略无法通过信任根认证的下载 Engine，并继续使用内置 Engine；应用绝不会降级为接受未签名更新。发布密钥配置和 Engine 包发布流程记录在 [`docs/RELEASE.md`](docs/RELEASE.md) 中。

## 系统维护命令

GitHub 构建不会安装特权 helper 或常驻 root 服务。系统命令助手只展示两条固定、可审计的命令，分别用于刷新 DNS 缓存和请求重建 Spotlight 索引。应用可以复制命令并打开终端，但不会执行 `sudo`、读取管理员密码，也不会根据用户输入拼接命令。命令由用户检查、粘贴并在终端中自行执行。

## 独立性声明

SpruceMyMac 与 Apple Inc.、Mole 项目以及 Mole for Mac 均无关联，也未获得其背书。Mac 是 Apple Inc. 的商标。

## 许可证

Copyright (C) 2026 Van426326 and contributors.

SPDX-License-Identifier: GPL-3.0-only。详见 [LICENSE](LICENSE)。
