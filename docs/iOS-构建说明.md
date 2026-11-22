# iOS 构建说明

> **现状**：这个项目是在 Windows 上开发的，**本机没有 macOS / Xcode，所以没有产出过 .ipa**。
> 下面这份说明是按工程现状写的：仓库里能提前做的都做了（图标、麦克风用途说明、Podfile、部署目标），
> 但「编译 + 签名 + 装到 iPhone」必须在一台 Mac 上完成。

## 0. 为什么 Windows 上做不了

- iOS 编译依赖 Xcode 里的 `xcodebuild` 与 iOS SDK，Apple 不提供 Windows 版本；
- 应用签名（证书 + Provisioning Profile）只能通过 Apple 开发者账号在 Xcode 里完成；
- 没有签名的 .ipa 只能装在越狱设备上，正常 iPhone 装不了。

所以「在 Windows 上生成苹果安装包」这件事本身不成立。要么借一台 Mac，要么用云端的 macOS 构建（GitHub Actions 的 macOS runner、Codemagic 等，需要你提供签名证书）。

## 1. 仓库里已经准备好的

| 项 | 状态 |
|---|---|
| 应用图标 | `ios/Runner/Assets.xcassets/AppIcon.appiconset/` 15 张齐全（含 1024） |
| 麦克风权限文案 | `ios/Runner/Info.plist` 的 `NSMicrophoneUsageDescription`（缺了会在请求麦克风时直接崩） |
| CocoaPods 配置 | `ios/Podfile`（platform 15.0，与工程里的 `IPHONEOS_DEPLOYMENT_TARGET` 一致） |
| 网络策略 | 全部接口走 HTTPS，未放开 ATS 明文 |
| 版本号 | 由 `pubspec.yaml` 的 `version:` 注入（当前 1.1.0 / build 2） |

还没准备、必须你在 Mac 上做的：

- **Bundle Identifier**：现在是模板默认的 `com.example.classnote`，上真机前要改成你自己的（Xcode → Runner → Signing & Capabilities）。
- **Team / 证书**：登录 Apple ID，选 Personal Team（免费，7 天有效）或付费开发者账号。
- **首次 `pod install`**：生成 `Pods/` 与 `Podfile.lock`。

## 2. 在 Mac 上的步骤

```bash
# 1) 依赖
flutter pub get
cd ios && pod install && cd ..

# 2) 打开工作区（不是 .xcodeproj）
open ios/Runner.xcworkspace
```

Xcode 里：

1. 左侧选 **Runner** → **Signing & Capabilities**
2. **Team** 选你的账号；**Bundle Identifier** 改成唯一值（如 `com.yourname.classnote`）
3. 连上 iPhone，顶部设备选真机，点 Run（第一次要在手机上「信任开发者」）

想直接出安装包：

```bash
flutter build ipa --release
# 产物：build/ios/ipa/classnote.ipa（需要已配置签名）
```

## 3. 装到别人手机上（三种方式）

| 方式 | 要求 | 适合 |
|---|---|---|
| Xcode 直连 | Mac + 数据线 | 自己调试 |
| TestFlight | 付费开发者账号（$99/年），上传 build 后邀请测试员 | 给几个人长期测试 |
| Ad Hoc | 付费账号 + 收集对方设备 UDID | 少量固定设备 |

免费 Apple ID 只能给自己装，且每 7 天要重签一次。

## 4. 已知的 iOS 侧风险

这些在 Windows 上无法验证，第一次在 Mac 上构建时请重点看：

1. **`flutter_foreground_task`**：Android 上是录音保活的关键；iOS 后台音频能力受限，长时间锁屏录音可能被系统挂起。需要在 Xcode 的 **Signing & Capabilities → Background Modes** 里勾上 **Audio, AirPlay, and Picture in Picture**，再实测锁屏 10 分钟是否还在录。
2. **`record` 插件**：iOS 需要麦克风权限，`Info.plist` 已配；若首次录音没声音，先看系统设置里 App 的麦克风开关。
3. **文件路径**：`path_provider` 在 iOS 返回沙盒目录，导出/分享走 `share_plus`，行为与 Android 不同，导出功能建议真机各点一遍。
4. **中文界面**：iOS 上字体渲染与 Android 略有差异，长文本换行位置可能不同，属于观感问题。

## 5. 想用 CI 出包

GitHub Actions 的 `macos-latest` 可以跑 `flutter build ipa`，但需要把证书（`.p12`）和描述文件（`.mobileprovision`）作为 Secrets 注入，并用 `xcodebuild -exportArchive` 导出。这套配置**本仓库没有预置**——签名材料属于个人凭据，不适合提交进仓库。需要的话可以单独加一个 workflow，把证书放在仓库 Secrets 里。