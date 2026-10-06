# LanShare iOS 端

局域网文件 / 文本互传的 iOS App，SwiftUI + 原生 BSD Socket 实现，
与 Windows 端 `LanShare.exe` 直接互通，无需服务器、无需联网。

## 功能

- **自动发现**：UDP 广播，2 秒一次，实时列出同一 Wi-Fi 下的 iPhone 与 Windows 设备
- **发送文本**：无字数限制，UTF-8 全支持（中文、emoji）
- **发送文件**：从「文件」App / 照片等选取，支持多选，流式发送，实时进度
- **接收**：App 前台常驻监听，文本直接查看与复制，文件保存到 App 目录并可系统分享（存储到文件、隔空投送等）
- 不依赖任何第三方库

## 工程结构

```
ios/
├── project.yml                          # xcodegen 工程描述
├── Sources/
│   ├── LanShareApp.swift                # 入口
│   ├── ContentView.swift                # 三个 Tab：设备 / 发送 / 接收
│   ├── DevicesView.swift                # 本机信息 + 设备列表
│   ├── SendView.swift                   # 发送文本 / 文件
│   ├── ReceivedView.swift               # 接收记录与导出
│   ├── LanShareModel.swift              # 全局状态与业务逻辑
│   ├── Discovery.swift                  # UDP 广播发现
│   ├── TransferServer.swift             # TCP 接收（边收边写盘）
│   ├── TransferClient.swift             # TCP 发送（流式）
│   ├── SocketIO.swift                   # 帧协议与 socket 读写工具
│   └── NetUtils.swift                   # 本机 IP / 广播地址 / 设备 ID
├── Resources/Assets.xcassets            # AppIcon
├── scripts/make_icon.py                 # 重新生成图标（可选）
└── .github/workflows/build-ipa.yml      # 云端编译 IPA
```

## 如何拿到 IPA

> IPA 只能在 macOS + Xcode 环境产出。Windows 下请用 GitHub Actions 云端编译。

### 方式一：GitHub Actions（推荐）

1. 新建 GitHub 仓库（建议 **Public**，公共仓库使用 macOS 云机免费）
2. **把 `ios/` 目录里的内容作为仓库根目录上传**（即仓库根下直接是 `Sources`、`project.yml`、`.github/`）
   - 隐藏目录 `.github` 无法拖拽上传，请在网页用 `Add file → Create new file`，
     文件名框直接填 `.github/workflows/build-ipa.yml`（斜杠会自动创建目录），粘贴工作流内容后提交
3. push 后 Actions 自动运行 `Build IPA`，约 6～10 分钟
4. 在该次运行页底部的 **Artifacts** 下载 `LanShare-unsigned-ipa`

### 方式二：本机 macOS

```bash
brew install xcodegen
xcodegen generate
open LanShare.xcodeproj      # Xcode 中 Run 到真机，或 Product → Archive
```

## 安装到 iPhone

未签名 IPA 需侧载（免费 Apple ID，7 天有效期）：

- **AltStore / SideStore**：Windows 装 AltServer，用 Apple ID 签名安装
- **Sideloadly**：拖入 IPA + Apple ID，一键安装
- 有 Mac：直接用 Xcode 真机运行

安装后首次打开会请求 **「本地网络」权限，必须允许**，否则发现不到设备。

## 自定义

- App 名称 / Bundle ID：改 `project.yml` 的 `INFOPLIST_KEY_CFBundleDisplayName`、`PRODUCT_BUNDLE_IDENTIFIER`
- 图标：替换 `Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`（1024×1024），或运行 `python scripts/make_icon.py`
- 端口：见 `Sources/SocketIO.swift` 中的 `LanShareProtocol`（发现 53520 / 接收 53521），与 Windows 端保持一致

## 分享扩展（用 LanShare 打开）

`ios/ShareExtension` 是一个 Share Extension 目标，让用户从「文件」等 App 选中任意文件 → 分享 → 用 LanShare 打开，文件会被推入 App 的「发送」页，随后可直接发给电脑。

- 扩展与主 App 通过 **App Group** 交换文件，已在两端 `*.entitlements` 中声明 `group.com.lanshare.app`。
- 打包 / 签名时必须让 App ID 具备该 App Group 能力（描述文件包含该 App Group）。
  - 免费 Apple ID（AltStore / Sideloadly 侧载）通常**不支持 App Group**，此时分享扩展无法跨进程传文件；如不需要该入口，可临时从 `project.yml` 删除 `ShareExtension` 目标及其依赖。
- 扩展把文件写入 App Group 的 `Inbox/manifest.json`；主 App 在启动与回到前台时（`LanShareModel.importSharedInbox()`）读取并移动到 `Documents/Imported`，随后在「发送」页展示。
- 若未启用 App Group，扩展会静默跳过，不会影响主 App 的其它功能。

## 已知限制

- iOS 在后台会挂起 App，**接收时请保持 App 在前台**（切换后台时会申请短暂的后台时间完成当前传输）
- 受 iOS 沙盒限制，接收的文件保存在 App 内目录，需要通过系统分享导出（或在「文件」App → 我的 iPhone → LanShare 中查看，已开启文件共享）
