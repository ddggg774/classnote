# 课堂笔记 App · 安卓打包与运行指南

这是一个用 Flutter 写的"课堂智能笔记"App：上课把老师讲的内容变成文字 → 一键 AI 总结 → 自动生成思维导图。以下带你从零跑起来并打出安卓 APK。

> **语音输入方式（重要）**：文字记录走**云端语音识别（硅基流动 SenseVoiceSmall）**——在记录页点「开始录音」说话，说完点「停止」，App 会把录音上传到硅基流动转成文字，自动追加到输入框。这样不依赖手机系统语音引擎，任何手机（包括没有 Google 语音服务的国产机）都能用。同时也保留手机输入法麦克风 🎤、手动打字、粘贴作为兜底。需在设置里填硅基流动 API Key（SenseVoiceSmall 模型**永久免费**，且手机浏览器即可申请）。

> 全程复制命令即可，遇到报错看文末「常见问题排查」。

## ✅ 构建状态（已实测通过）

本项目已在 **Flutter 3.50.0 / Dart 3.14** 环境下成功编译（本机缺 Android SDK，见下方"当前验证状态"）：

- 产物：`build/app/outputs/flutter-apk/app-release.apk`（v2 签名）
- 已验证：APK 签名有效、可安装
- 静态检查 `flutter analyze`：**No issues found（0 条）**
- 语音方案已改为「云端识别」：App 录音 → 上传硅基流动（SenseVoiceSmall，永久免费）转成文字，不依赖系统语音引擎，国产手机也能正常用

> 说明：release 包用的是 Flutter 自动生成的调试签名，**可直接安装测试**。若要正式上架，请按下面 3.2 节配置自己的正式签名。

### 当前验证状态（2026-11-20 详细笔记改版后）

| 项 | 状态 |
|---|---|
| `flutter analyze` | ✅ No issues found |
| `flutter test` | ✅ 26 个单元测试全部通过 |
| `flutter build apk --release` | ✅ 成功，50.2MB，签名已验证 |

> APK：`build/app/outputs/flutter-apk/app-release.apk`，副本 `E:\Downloads\classnote-release.apk`
>
> **构建须知（这台机器的两个坑，换机器可忽略）**：
> 1. 用户名含中文（`C:\Users\金运来`）会让 `jni` 插件的 CMake/ninja 报
>    `FindFirstFileExA` 路径语法错误。解决：把 `PUB_CACHE` 指到纯英文路径
>    （本机用 `E:\dev\pub-cache`，已复制好）。
> 2. `storage.googleapis.com` 在本机被解析到 `127.0.0.1`，Flutter 引擎产物拉不下来。
>    已在 `android/settings.gradle.kts` 追加 `storage.flutter-io.cn` 镜像仓库。
>
> **详细的改动清单、每处改了什么为什么、以及 15 条必测场景，见 [优化改动说明.md](./优化改动说明.md)。**
> 改动前的原始版本备份在 `E:\Downloads\_backup\classnote_backup_20261118_224041\`，且项目内已 `git init`，
> `git diff 634abf1` 可查看全部改动，`git checkout 634abf1` 可回滚。

---

## ✨ 已实现功能

- **语音转文字**：点「开始录音」说话、点「停止」后自动上传云端转成文字；也能用输入法麦克风 🎤、手动打字、粘贴（兼容所有手机）
- **自动分段 + 失败重试**：每 60 秒自动切一段上传，60 秒内就能看到第一批文字；某段失败会自动退避重试 3 次，仍失败则在正文标出位置并可一键补传
- **实时进度**：录音时顶部显示已录时长、第几段、已转写段数、排队段数
- **锁屏可录**：录音期间起前台服务 + 常驻通知（显示已录时长），锁屏放桌上也能继续录，不怕系统回收进程
- **崩溃可恢复**：录音一开始就落草稿，每段识别完成即写库；中途被杀/误退后，首页「未完成」分区可以继续
- **一键 AI 详细笔记**：点「一键总结」生成**九段式**详细课堂笔记（课程信息 / 知识点结构 / 例题与解题步骤 / 老师强调与考试作业提示 / 课堂互动问答 / 术语表 / 学习任务表 / 疑问待确认清单 / 时间戳回溯），可直接复制或导出 `.md` 二次编辑
- **不编造、缺口标注**：转写不清、公式数字可疑的地方标〔待确认〕〔转写缺失〕，不会瞎补
- **长课堂自动分块**：两小时课堂先分块整理再合并成完整笔记，不会超上下文
- **思维导图**：自动按「主题 → 要点 → 子点」生成，可导出为图片分享
- **API Key 应用内设置**：不用改代码、不用重新打包，装好后在 App 里填 Key 即可

---

## 第 0 步：填写两个 API Key（都在 App 内操作）

**无需改代码或重新打包**，装好 App 后：首页右上角「⚙ 设置」，填两个 Key 并保存。

### Key ① 硅基流动（语音转文字，必须）
> 选它的原因：**手机浏览器就能申请**（不像阿里云百炼强制电脑端），且 SenseVoiceSmall 识别模型**永久免费**。

1. 手机浏览器打开 <https://cloud.siliconflow.cn>，手机号注册登录。
2. 完成**实名认证**：支付宝刷脸，约 2 分钟（免费，不实名不能用）。
3. 进入控制台 →「API 密钥」→ 创建并复制 Key（形如 `sk-xxx`，**只显示一次，立即复制**）。
4. 粘贴到 App 设置页的「① 硅基流动 API Key」。

> 费用：所用的 `FunAudioLLM/SenseVoiceSmall` 模型官方标注**永久免费**，日常上课语音转文字不花钱。免费模型速率有限，正常上课够用。

### Key ② DeepSeek（AI 总结，必须）
1. 打开 <https://platform.deepseek.com> → 注册登录 →「API Keys」→ 创建。
2. 粘贴到 App 设置页的「② DeepSeek API Key」。

> 两个 Key 都只保存在本机，不会上传。语音识别需要联网。

---

## 第 1 步：安装环境（一次性）

需要两个东西：**Flutter SDK**（编译 App 的框架）和 **Android Studio**（提供安卓 SDK 和模拟器）。

### 1.1 安装 Flutter SDK

国内用户建议配置镜像，加速下载：

```bash
# 到 https://docs.flutter.cn/get-started/install 下载对应系统的 SDK 并解压
# 假设解压到 ~/flutter，把下面两行加进 ~/.bashrc 或 ~/.zshrc
export PATH="$HOME/flutter/bin:$PATH"
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn

# 让配置生效
source ~/.bashrc   # zsh 用户用 source ~/.zshrc

# 检查是否装好（出现版本号即成功）
flutter --version
```

### 1.2 安装 Android Studio

1. 到 <https://developer.android.com/studio> 下载安装。
2. 打开 Android Studio → `More Actions` → `SDK Manager` → 勾选安装：
   - **Android SDK Platform 34**（或最新版）
   - **Android SDK Build-Tools**
   - **Android SDK Command-line Tools**
3. 同意许可协议：

```bash
flutter doctor --android-licenses   # 一路输入 y 回车
```

### 1.3 体检

```bash
flutter doctor
```

只要 Android 相关项都打勾（✓）即可。iOS 项不用管（我们先做安卓）。

---

## 第 2 步：拉取依赖并运行

在项目根目录执行：

```bash
cd classnote

# 下载项目依赖（第一次会慢一点）
flutter pub get

# 连接真机（开启手机"开发者模式 + USB调试"）或启动 Android Studio 模拟器后，查看是否识别到设备
flutter devices

# 运行到设备/模拟器
flutter run
```

看到 App 界面就说明跑通了。真机测试语音转写效果最准（模拟器可能没有语音服务）。

---

## 第 3 步：打出安卓 APK 安装包

APK 是安卓手机能直接安装的包。分两种：

### 3.1 先打一个测试包（debug，快速验证）

```bash
flutter build apk --debug
```

产物在 `build/app/outputs/flutter-apk/app-debug.apk`，发到手机安装即可。

### 3.2 打正式签名包（release，可分发）

正式包需要用"签名文件"签名，步骤如下：

**① 生成签名文件（只需做一次）**

```bash
keytool -genkey -v -keystore ~/classnote-key.jks -keyalg RSA -keysize 2048 -validity 10000 -alias classnote
```

执行后会问你设密码和填写信息，务必记住 **keystore 密码** 和 **alias 密码**（后面要用）。

**② 新建 `android/key.properties` 文件**（内容如下，密码换成你自己的）

```properties
storePassword=你的keystore密码
keyPassword=你的alias密码
storeFile=/home/你的用户名/classnote-key.jks
keyAlias=classnote
```

**③ 修改 `android/app/build.gradle.kts`**（新版 Flutter 用 Kotlin DSL，文件名带 `.kts`）

先在文件顶部 `plugins {` 之前加入读取签名的代码：

```kotlin
import java.util.Properties
import java.io.FileInputStream

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
```

然后在 `android { ... }` 内部、`buildTypes` 之前加入 `signingConfigs`：

```kotlin
signingConfigs {
    create("release") {
        keyAlias = keystoreProperties["keyAlias"] as String
        keyPassword = keystoreProperties["keyPassword"] as String
        storeFile = keystoreProperties["storeFile"]?.let { file(it) }
        storePassword = keystoreProperties["storePassword"] as String
    }
}
```

最后把 `buildTypes` 里 release 的签名从 debug 改为 release：

```kotlin
buildTypes {
    release {
        signingConfig = signingConfigs.getByName("release")
    }
}
```

**④ 打包**

```bash
flutter build apk --release          # 通用包，兼容所有安卓机
# 或
flutter build apk --split-per-abi    # 按 CPU 架构分包，体积更小
```

产物在 `build/app/outputs/flutter-apk/` 下，把 `app-release.apk` 发到手机安装即可。

> ⚠️ `key.properties` 和 `*.jks` 签名文件=你的 App 身份凭证，**务必备份且不要泄露/上传公开仓库**，丢失后无法给同一 App 更新。

---

## 第 4 步：真机安装测试

1. 手机开启「设置 → 关于手机 → 连点版本号 7 次」进入开发者模式。
2. 打开「开发者选项 → USB 调试」。
3. 数据线连电脑，把 APK 传到手机点开安装。
4. 首次安装会提示"允许安装未知来源应用"，选允许。
5. 打开 App → 允许麦克风权限 → 新建课堂 → 说几句话看是否实时出字 → 完成 → 一键总结。

---

## 常见问题排查

| 报错 / 现象 | 原因与解决 |
|---|---|
| `cmdline-tools not found` / `Android license status unknown` | Android Studio 里装 Command-line Tools，再跑 `flutter doctor --android-licenses` |
| `Gradle build failed` / 卡在 Gradle | 项目目录执行 `flutter clean` 然后 `flutter pub get` 再打包 |
| 打包报签名相关错误 | 检查 `key.properties` 路径和密码是否正确，alias 是否一致 |
| 语音识别不出字 / 报 401、403 | 真机测试；确认已授予麦克风权限；确认设置里填了硅基流动 Key 且已完成实名认证 |
| 一键总结报 `401` | App「设置」里的 API Key 没填或填错 |
| 一键总结报 `402` / `429` | 账户余额不足 / 请求太快，稍后重试或充值 |
| 录到一半锁屏后没声了 | 已加 `wakelock_plus`，但部分国产 ROM 仍需在「设置 → 应用 → 课堂笔记 → 电池」里关掉省电限制、并允许自启动。彻底方案是前台服务（见下） |
| 某段文字显示「〔第 N 段语音识别失败〕」 | 该段重试 3 次仍失败（多为弱网）。点录音页状态条的「重试失败段」补传即可，音频文件有保留 |
| 老版本升级后 Key 没了 | 不应发生：旧键名 `aliyun_asr_key` 会自动迁移到 `siliconflow_asr_key`。若真遇到，请反馈 |
| `CocoaPods not installed` | 这是 iOS 才会遇到的，做安卓可忽略 |

---

## 说明与边界

- 本指南只做**本地打包**，帮你得到可安装的 APK 文件，不涉及应用商店上架、资质审核、备案等。
- iOS（IPA）需要苹果开发者账号（¥688/年）或 TestFlight 才能安装，且必须在 macOS + Xcode 环境打包，本 App 代码已兼容双端，届时可直接构建。
- App 内 AI 总结会联网调用 DeepSeek，产生少量 API 费用（按字数计费，很便宜）；语音转文字走硅基流动 SenseVoiceSmall 模型，永久免费。两者都需联网。

### 已知限制

- **锁屏录制**：已接前台服务 + 常驻通知，理论上可覆盖锁屏长时间录制。但部分国产 ROM（MIUI/EMUI/ColorOS 等）仍可能额外杀后台，建议在「设置 → 应用 → 课堂笔记 → 电池」里关掉省电限制、并允许自启动。真机验证前请先按 [优化改动说明.md](./优化改动说明.md) 第四节走一遍。
- **上传流量**：每 60 秒一段 wav ≈ 1.9MB，一小时约 115MB。改用 AAC 可降到 1/5，但**必须先验证 SenseVoiceSmall 接受 m4a 容器**，否则会把"能转"变成"全转不了"，本次未改。
- **导图导出**：已做 pixelRatio 自适应防 OOM，但极长导图（超过 4000 逻辑像素）在低端机上仍可能偏慢。
- **构建环境**：本机为了关掉 Kotlin 增量编译缓存报错，在 `android/gradle.properties` 里设了 `kotlin.incremental=false`，编译会慢一点（约 115 秒）但稳定。
