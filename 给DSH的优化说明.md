# 任务：优化「课堂笔记」Flutter App

## 项目背景
这是一个课堂智能笔记 App（Flutter，一套代码打 Android APK）：
上课录音 → 云端语音识别转文字 → 一键 DeepSeek AI 总结 → 生成思维导图 → 可导出图片。
项目就在这个 zip 解压后的 `classnote/` 目录里，源码在 `lib/` 下。

## 优化前必做
1. 先把整个 classnote 目录完整备份一份（tar.gz 或复制一份），再动手改。
2. 确认本机有 Flutter SDK（建议 3.50+ / Dart 3.14+）和 Android SDK 36，否则无法编译验证。
3. 依赖已配好：speech_to_text、http、sqflite、uuid、shared_preferences、share_plus、path_provider、record。国内拉依赖可设 PUB_HOSTED_URL=https://pub.flutter-io.cn。

## 当前代码结构
- lib/config.dart — 接口地址和模型配置（DeepSeek 总结接口、硅基流动语音识别接口）
- lib/models/note.dart — 笔记数据模型
- lib/services/db_service.dart — SQLite 本地存储
- lib/services/settings_service.dart — Key 本地存储（DeepSeek Key / 硅基流动 Key）
- lib/services/cloud_asr_service.dart — 录音 + 自动分段（每 5 分钟一段）+ 上传硅基流动识别
- lib/services/ai_service.dart — 调 DeepSeek 做总结，输出结构化要点
- lib/pages/home_page.dart — 笔记列表
- lib/pages/record_page.dart — 录音/输入转写页
- lib/pages/note_detail_page.dart — 原文/总结/导图三 Tab 详情
- lib/pages/settings_page.dart — 设置页（填两个 Key）
- lib/widgets/mind_map_widget.dart — 树状思维导图 + 导出图片

## 已知情况 / 注意事项
- 语音识别已弃用系统 speech_to_text，改为录音上传硅基流动 SenseVoiceSmall（永久免费、手机可申请 Key）。
- 设置里的 Key 存在本机 shared_preferences，改 Key 无需重新打包。
- release 包用 Flutter 自动签名，可直接安装测试。
- flutter analyze 无 error，仅若干 info 级弃用提示（material.dart 弃用等），不影响编译。

## 请你（DSH）帮我做的优化（按需勾选/补充）
> 下面是可选的优化方向，我还没定具体做哪些。请先通读代码，给出一份「优化建议清单」，列清楚每项的价值、改动量、风险，等我确认后再动手改。

候选方向：
1. 稳定性：语音分段上传失败重试、弱网处理、避免文字丢失或乱序
2. 性能：录音文件压缩后再上传（减小体积、加快识别）
3. 体验：录音时实时显示已录时长/分段进度、识别中的状态提示
4. 代码质量：清理 deprecated 警告、抽重复逻辑、加注释
5. Bug 排查：仔细检查 three Tab 切换、Key 读取、录音生命周期是否有隐患
6. 其他：你读完代码后觉得值得优化的点

## 要求
- 破坏性改动前先备份。
- 每改一处说清楚改了什么、为什么。
- 改完跑 `flutter analyze` 和 `flutter build apk --release` 验证，确认能编译。
