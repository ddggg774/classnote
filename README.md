# classnote · 课堂笔记

把一节课变成可复习的笔记：**录音 → 云端转写 → 术语纠错 → 三档总结 → 思维导图 → 知识沉淀**。Flutter 写的 Android / iOS App，数据全在本机，模型直连 DeepSeek 与硅基流动，不需要自建服务器。

![应用图标](assets/branding/app_icon_512.png)

## 它能做什么

| 环节 | 说明 |
|---|---|
| 录音转写 | 60 秒切片上传硅基流动（SenseVoiceSmall 免费），串行识别、失败重传、前台服务保活 |
| 术语纠错 | 课前按「课程 + 章节」生成术语表与常见误听形式，纠错子 Agent 只改高置信项，其余标待确认 |
| 三档总结 | 速览 / 九段式 / 详细（带原文引用），超长课堂自动分块再合并 |
| 思维导图 | 3–5 级结构，树形、2D 画布两种视图，可导出 PNG / Markdown / Markmap / Mermaid / OPML |
| 教材定位 | 教材库 + 章节目录（粘贴解析或手动录入），录音前定位到「第五章 第二节」，位置喂给术语与总结 |
| 检索问答 | 自建 bigram 倒排索引（不依赖 FTS5），全局搜索 + 带出处的跨笔记问答 |
| 知识库 | 课程级 Wiki 词条，增量抽取，定义冲突不覆盖、留待人工裁定 |

## 快速开始

### 需要

- Flutter 3.50+ / Dart 3.14+
- 两个 Key（App 内「设置」页填写，只存本机）：
  - **DeepSeek**：总结、纠错、术语表、Wiki —— https://platform.deepseek.com
  - **硅基流动**：语音转写 —— https://cloud.siliconflow.cn （SenseVoiceSmall 免费）

### Android

```bash
export JAVA_HOME=/path/to/jdk-21
export ANDROID_HOME=/path/to/android-sdk
export PUB_CACHE=/path/to/ascii/pub-cache   # 必须是 ASCII 路径，中文用户名会炸 jni 的 CMake

flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

产物在 `build/app/outputs/flutter-apk/app-release.apk`。

> 构建环境踩过的坑写在 [docs/项目状态快照.md](docs/项目状态快照.md) 的「构建命令」一节，包括 Gradle 镜像位置与签名验证的 JAVA_HOME 写法。

### iOS

iOS **必须在 macOS + Xcode 上构建**，Windows 无法产出 IPA：

```bash
flutter pub get
cd ios && pod install && cd ..
open ios/Runner.xcworkspace     # 在 Xcode 里配 Team 与 Bundle Identifier
flutter build ipa --release      # 或 Xcode → Product → Archive
```

详细步骤与签名说明见 [docs/iOS-构建说明.md](docs/iOS-构建说明.md)。

## 架构

```
lib/
├── agent/        Function Calling 循环（纯 Dart + http 直连，无框架）
│   ├── agent_loop.dart        循环、maxSteps 硬上限、结构化日志
│   ├── correction_agent.dart  纠错子 Agent：查术语表 → 逐条判断 → 标待确认
│   ├── classroom_agent.dart   顶层编排，按技能收窄提示词与工具
│   └── terminology_store.dart 术语表按「课程 + 章节」缓存
├── models/       Note / StudySummary / MindGraph / Textbook / CourseLocation …
├── services/     AI、ASR、纠错、检索、Wiki、教材、数据库
├── pages/        首页 / 录音 / 笔记详情 / 设置 / 搜索 / Wiki / 教材
└── widgets/      画布、导图、Agent 运行面板、位置选择器
```

几条关键取舍：

- **Agent 写在 App 内**，不是 Python 服务器。Function Calling 本质是 HTTP+JSON，多一层服务器只会让体验退化。
- **不用 FTS5**。`sqflite` 走系统 SQLite，厂商 ROM 会裁掉 FTS5；改用普通表自建 bigram 倒排，100% 可用。
- **教材目录绝不由模型生成**。解析器先走正则，认不出的行丢弃并计数；模型兜底时输出每行都必须能在用户原文里找到，否则丢弃。
- **总结不按字数裁剪**，按「允许出现哪些章节」的档位白名单控制，避免模型注水或删干货。

## 测试

```bash
flutter test                                  # 373 通过 + 29 跳过（跳过的是需 Key 的真实 API 用例）
DS_KEY=sk-xxx flutter test test/real_api_*.dart   # 真实 API 冒烟
```

纯逻辑（切词、目录解析、布局几何）、真实 SQL（`sqflite_common_ffi`）、widget（画布手势、位置选择器）分层覆盖。

## 目录里的文档

| 文档 | 内容 |
|---|---|
| [docs/项目状态快照.md](docs/项目状态快照.md) | 当前状态、代码地图、数据库演进、已知坑、自检记录 |
| [docs/DSH-教材检索提示词.md](docs/DSH-教材检索提示词.md) | 教材定位功能的完整规格 |
| [docs/改造清单-教材检索.md](docs/改造清单-教材检索.md) | 实施记录与偏差 |
| [docs/DSH-课堂图片笔记提示词.md](docs/DSH-课堂图片笔记提示词.md) | 课堂图片导入的待实现规格 |
| [docs/DSH-多语言与翻译提示词.md](docs/DSH-多语言与翻译提示词.md) | 英语课转写、逐句对照翻译与交付记录 |
| [docs/免责声明.md](docs/免责声明.md) | 使用协议：录音合规、AI 边界、第三方服务、担保排除 |
| [docs/iOS-构建说明.md](docs/iOS-构建说明.md) | iOS 打包与签名 |

## 已知限制

- 语音识别只走云端，离线不可用；手写板书识别尚未实现（见图片笔记提示词）。
- 数据库目前 v10，升级分支都带可重入保护，但真机跨版本升级建议先备份。
- release APK 使用 debug 签名，仅用于侧载测试，不能上架。
- 术语缓存的完整链路（课前预生成 + 纠错命中）仍在收尾。

## 使用前必读

本应用会录课堂声音，并把录音片段（语音识别）与文本（纠错/总结/翻译）发送给你自己配置的第三方 AI 服务。使用前请注意：

1. **录课前征得老师与在场同学同意**，遵守学校规定；录音只用于个人学习，不传播、不营利、不用于作弊或抄袭；
2. 转写、翻译、总结均由 AI 生成，**可能出错甚至编造**，考试与作业内容必须自己核对教材与原文；
3. 第三方服务（硅基流动、DeepSeek）的费用由你自行承担，数据处理受其各自条款约束；
4. 数据只存本机，卸载或清数据会永久丢失，重要笔记请自行备份。

首次启动时应用会强制显示完整条款并要求勾选同意，不同意则无法使用。全文见 [docs/免责声明.md](docs/免责声明.md)（版本 1.0）。

## 许可

[MIT](LICENSE)。可以自由使用、修改、商用；如果它帮到了你，欢迎回来说一声。

项目里的第三方服务（DeepSeek、硅基流动）由使用者自行申请与付费，与本仓库无关。