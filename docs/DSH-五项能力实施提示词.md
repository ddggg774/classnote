# classnote 五项能力扩展 · DSH 实施提示词

> **怎么用**：新开一个 DSH 会话，从下面 `### 你是谁` 这一行开始全选到文档末尾，整段复制发送即可。
> 前面的「一、背景」是给你（人）看的，不用复制。
> 建议新开一个会话执行，避免和当前会话上下文混淆。

---

## 一、背景（给人看，说明这份提示词为什么这么写）

classnote 已经是一个能在真机上跑的课堂录音笔记 App，核心链路完整：录音 → 转写 → 术语纠错 → 三档总结 → 思维导图 → 落库。
现在要补的五项，本质上是从「一次性的笔记工具」升级成「可持续积累的学习系统」：

| 能力 | 解决的问题 | 现状缺口 |
|---|---|---|
| 模板整理 | 所有课都用同一套九段式，实验课/制图课/复习课不该长一样 | 格式写死在 3 个 prompt 常量里 |
| LLM Wiki | 每节课的笔记互相孤立，同一门课上了十节也没有沉淀 | 只有按「课程+章节」缓存的术语表 |
| RAG 检索 | 想找"老师上次讲木兰科怎么说的"，只能一页页翻 | 完全没有跨笔记检索 |
| MCP/Skills | 处理流程固定四步，想加"生成复习题"就得改代码 | Agent 工具集写死 |
| 画布 | 现在只有「主图+可折叠树」，看不到全局结构 | 没有真正的 2D 画布 |

提示词里我特意加了三类东西，是这轮改代码踩出来的真实教训：
1. **原生编译类依赖的高风险**（RNNoise 那次失败）→ 让执行者优先选纯 Dart
2. **测试环境把 HTTP 拦成 400** → 真实 API 测试必须注入 Key
3. **构建必须设的环境变量**（中文路径、镜像）→ 不设就是一堆莫名其妙的错

---

## 二、任务提示词（复制下面这一整段给 DSH）

### 你是谁

你是 classnote 这个 Flutter 课堂笔记 App 的开发者与唯一维护人。用户是林业专业学生，实际课程是植物学（方炎明《植物学》第三版，中国林业出版社）、建筑制图（第四版，东南大学出版社）、园林制图。他上课坐得远、录音质量差、专业术语常被识别错。

项目路径：`E:\Downloads\classnote`

### 当前代码现状（已核实，不要重新猜）

**已完成并跑通的能力**：

```
lib/
├── agent/                    # Agent 层（纯 Dart + http 直连 DeepSeek，无任何框架）
│   ├── agent_tool.dart       # AgentTool / ToolResult / Schema / ToolRegistry
│   ├── agent_loop.dart       # Function Calling 循环，max_steps 硬上限，AgentStep 结构化日志
│   ├── correction_agent.dart # 纠错子 Agent（lookup_terminology / flag_uncertain / mark_missing）
│   ├── classroom_agent.dart  # 顶层编排（transcribe / run_correction_agent / summarize / generate_mindmap）
│   └── terminology_store.dart# 术语表按「课程+章节」落 SQLite 缓存
├── models/
│   ├── note.dart             # Note + legacy MindMapData/MindNode
│   ├── study_note.dart       # StudySummary（detailMarkdown + mindMap + graph + pending）
│   ├── mind_graph.dart       # MindGraph 3-5 级递归 + NodeMark 枚举 + 11 个必需一级分支
│   ├── terminology.dart      # TerminologyPack / CalibrationReport / PendingItem（含 positions 定位）
│   └── summary_level.dart    # brief / normal / detail 三档
├── services/
│   ├── ai_service.dart       # 九段式总结 + 分块合并 + 三档提示词构造函数
│   ├── cloud_asr_service.dart# 录音（60s 切片、串行上传、失败重传、前台服务、唤醒锁）
│   ├── transcript_corrector.dart # A/B/C 三档校准
│   ├── terminology_service.dart  # 课前术语表生成
│   ├── db_service.dart       # SQLite v4（notes + terminology_cache）
│   ├── settings_service.dart # Key / 模型 / 术语表 / 自动纠错 / 拾音档位
│   ├── mind_graph_exporter.dart # Markdown / Markmap HTML / Mermaid / OPML / JSON
│   ├── pending_fixer.dart    # 待确认项替换 + 位置重算
│   ├── audio_capture_profile.dart # 远场拾音三档（降噪/AGC/AEC）
│   └── foreground_service.dart    # 前台服务保活
├── pages/                    # home / record / note_detail / settings
└── widgets/                  # mind_graph_tree / mind_map_widget / agent_run_sheet
```

**数据库**：`dbVersion = 4`，表 `notes`（id/title/transcript/summary_json/created_at/duration/status/terminology_json）+ `terminology_cache`（cache_key/course/chapter/pack_json/updated_at）。迁移分支逐版本可重入。

**测试**：15 个测试文件，145 通过 + 10 跳过（跳过的是需 Key 的真实 API 用例）。

**最近 5 个提交**：`2bdfa54` 远场拾音三档 / `62e14b6` 待确认一键替换 / `14010fd` 待确认可定位持久化 / `df0173b` 一键处理入口 / `80376a3` 顶层编排 Agent 接真实现。

### 硬约束（违反任何一条都算做错）

1. **保留现有已跑通的功能，不要推倒重写。** 动手前先读代码，列出改造点，确认后再改。
2. **不引入外部平台或框架。** 不要 Dify、n8n、LangChain、MCP SDK 之类。所有逻辑写成代码里的常量或函数，你能完整读写和修改。
3. **优先纯 Dart 方案。** 这台机器上带原生编译的三方包风险极高（见「已知坑」第 1 条）。
4. **分阶段交付，每阶段跑通再进下一阶段。** 每阶段先输出改造清单，用户确认后才动代码。
5. **不确定 > 猜测。** 拿不准的内容标「待确认」，绝不编造。这条对纠错、总结、Wiki 抽取都适用。
6. **不要为了让测试通过而改测试的期望值。** 测试挂了先查是代码错还是断言错——上一轮我自己写错过一次期望字符位置，是断言抓出来的。

### 五项能力：需求定义与优先级

按「投入产出比」排序，建议按这个顺序做。每项都写清了现状缺口和验收标准。

---

#### 第 1 项：模板整理（优先级最高，风险最低）

**现状缺口**：总结格式硬编码在 `ai_service.dart` 的三个常量里（`_detailSystemPrompt` / `_chunkSystemPrompt` / `_mergeSystemPrompt`），三档只是章节取舍。想加个"实验报告格式"就得改源码。

**要做的**：
- 把「笔记模板」抽成数据：每个模板 = 名称 + 适用场景 + 章节结构（节名 + 是否必需 + 写作要求）+ 是否要导图 + 是否要原文引用
- 内置至少 4 个模板：
  - `九段式`（现有，默认，通用课堂）
  - `速览`（现有 brief 档那三节）
  - `实验/实习报告`（目的 / 材料与方法 / 步骤 / 结果 / 讨论 / 结论）
  - `制图与规范`（图名 / 图幅规格 / 线型与线宽 / 尺寸标注 / 投影关系 / 常见错误 / 作业要求）—— 专为建筑制图、园林制图
- 模板按「课程」自动匹配（沿用 `AppConfig.textbooks` 的模糊匹配思路），也可手动选
- 用户可自定义模板（至少能改节名与顺序），存 SQLite
- `AiService.buildPromptForLevel` 改为 `buildPrompt(template, level, courseName)`

**验收**：
- 同一段转写，用「实验报告」和「九段式」产出的章节结构明显不同
- 植物学课默认九段式，建筑制图课默认制图模板
- 自定义模板能存能读，重启 App 还在
- 现有 145 个测试不回归（尤其 `prompt_build_test.dart`）

---

#### 第 2 项：RAG 检索（优先级次高，能立刻见效）

**现状缺口**：完全没有跨笔记检索。用户想找"老师上次讲木兰科怎么说的"只能一页页翻。

**要做的**：
- **第一版必须用 SQLite FTS5**（`sqflite` 自带，零依赖零成本），不要一上来就搞向量
  - 中文难点：FTS5 默认分词对中文不友好。用 **character bigram** 方案——把「木兰科」拆成「木兰」「兰科」建索引，查询时同样拆。这是不引入分词库的可行解
  - 建索引表：`notes_fts`（note_id, title, transcript, summary）用 FTS5 external content 关联 `notes`
  - 每次保存/更新笔记时同步索引
- 检索界面：全局搜索框（首页），结果高亮命中片段 + 显示来自哪节课 + 点进去跳转到原文位置
- **第二版（可选增强）**：接 embedding 精排。硅基流动有 embedding 接口，复用现有 ASR 的 Key。向量存 SQLite，用朴素 cosine（节点量小，不需要 FAISS）。**不要用 sqlite-vec 这类原生扩展**，理由见已知坑第 1 条
- 检索到的片段要能喂给 LLM 做"跨笔记问答"（复用 `AiService` 的调用方式，但用新的提示词：只根据检索到的内容回答，找不到就说找不到，严禁编造）

**验收**：
- 输入「木兰科」能搜出讲了木兰科的所有笔记，并高亮上下文
- 搜索「离生心皮」这类术语，即使原文写的是「离心皮」也能通过 bigram 部分命中
- 跨笔记问答：「这学期木兰科讲过几次」能给出带出处的答案
- 索引在笔记新增/修改/删除后保持一致（用测试锁住）

---

#### 第 3 项：LLM Wiki（依赖第 1、2 项）

**现状缺口**：每条笔记孤立。同一门课上了十节，术语、人物、公式、易错点没有任何沉淀。只有按章节缓存的术语表。

**要做的**：
- 以「课程」为单位建词条库。词条结构：
  ```
  term（词条名）/ course / type（术语|人物|公式|概念|易错点|例题套路）
  definition（定义，可多行）
  sources[]（出处：note_id + 原文片段 + 时间戳）
  related[]（关联词条 id）
  variants[]（其他写法/别称/常见误听）
  first_seen / last_updated
  ```
- 新笔记落库后，**增量抽取**：让 LLM 从笔记里抽出候选词条，与已有词条比对——合并（补充定义/新增出处）、新建、或标记冲突
- **冲突处理是重点**：同一词条两次抽取定义不一致时，不要覆盖，保留两个版本 + 各自出处，界面标「待核对」
- Wiki 浏览界面：按课程分组、按类型筛选、搜索、点词条看定义与所有出处（能跳回原文）
- 词条与术语表打通：Wiki 里的 `variants` 可以喂给纠错 Agent 的 `lookup_terminology`

**验收**：
- 连续处理 3 节植物学课后，Wiki 里有 20+ 词条，且每个词条能追溯到具体某节课的原文
- 同一术语在两节课定义不同时，两条都保留、都标出处、界面提示冲突
- 新增词条不会破坏已有词条（幂等：同样的笔记重复抽取不产生重复词条）

---

#### 第 4 项：画布（优先级中，纯前端，风险可控）

**现状缺口**：`mind_graph_tree.dart` 是「主图（11 个一级分支）+ 点进分支看可折叠树」。看不到全局结构，也没法缩放平移。

**要做的**：
- 真正的 2D 画布：节点可拖、画布可缩放平移、能看到 3-5 级全貌
- 技术：`CustomPaint` + `Matrix4` 手势变换（**不要用 InteractiveViewer 套复杂手势，会和节点拖拽冲突**）
- 布局算法：层次树布局（Reingold-Tilford 或简化的递归布局），一级分支水平排开、子节点垂直展开
- 性能：几百节点要流畅。用 `RepaintBoundary` 隔离、只重绘变化的层、节点文本用 `TextPainter` 缓存
- 保留现有的折叠树视图作为备选（屏幕小的时候树更好用），画布和树可切换
- 导出：现有的 PNG 导出基于 `mind_map_widget.dart`，画布要有自己的导出（把画布渲染成图片，注意 `pixelRatio` 与内存上限）

**验收**：
- 11 分支 40+ 节点的导图能在画布上完整显示、缩放平移跟手
- 拖节点时不会触发画布平移（手势不打架）
- 节点文字在缩放后仍清晰（不是位图拉伸）
- 树视图和画布视图切换时数据一致
- 画布导出 PNG 与原图内容一致

---

#### 第 5 项：MCP/Skills（优先级最低，风险最高，建议降级实现）

**现实判断（必须诚实告诉用户）**：
- 真正的 **MCP 客户端**需要实现 SSE/HTTP 传输 + JSON-RPC + 能力协商，在移动 App 里做完整 MCP 客户端工作量大且没有明确收益（用户的 MCP server 场景不清晰）
- 更合理的是先做 **App 内部的 Skills 系统**——借鉴"技能"思想，把处理流程做成可插拔的包

**建议做法（内部 Skills）**：
- 每个 Skill = 名称 + 触发条件（用户选了它/笔记类型匹配）+ 输入输出 schema + 提示词 + 可选工具集
- 内置技能示例：`术语纠错` / `九段式总结` / `生成复习题` / `提取考点清单` / `对比两节课`
- 技能可启停，可组合编排（"一键处理"从固定四步变成"按技能清单跑"）
- `classroom_agent` 的工具集从硬编码改为按 Skill 动态组装
- **MCP 接口预留**：定义一个 `SkillProvider` 抽象，将来真要接 MCP server 时实现这个接口即可，不用改业务层

**验收**：
- 至少 3 个内置技能可独立启停
- 「一键处理」的运行步骤随启用的技能变化（关掉总结就真的不调 summarize）
- 加一个新技能只改一个文件（不改 agent 循环、不改页面）
- `SkillProvider` 抽象存在且有至少一个内部实现

---

### 关键技术判断与风险预警

1. **涉及原生编译的依赖，一律先验证再承诺。**
   上一轮集成 RNNoise 降噪（`flutter_nnnoiseless`）失败收场，三个障碍叠加：cargokit 用了 Gradle 9 已移除的 `Project.exec()`、要求 NDK 29、包内无预编译 `.so` 需本地交叉编译 Rust。最后卡在 **Windows 开发者模式未开启导致 Flutter 无法创建 symlink**。
   **结论**：FTS5、CustomPaint、SQLite 这些都是纯 Dart/平台内置，安全。`sqlite-vec`、`flutter_nnnoiseless` 这类要原生扩展的，先做一次最小验证构建，别在架构里先假设它可用。

2. **测试环境会把所有 HTTP 请求拦成 400。**
   用 `TestWidgetsFlutterBinding` 时网络请求全部返回 400，且读不到 SharedPreferences。
   **做法**：服务类都要支持显式注入（`AiService({this.apiKeyOverride})`、`TerminologyService({this.apiKeyOverride})`）。真实 API 测试放 `test/real_api_*.dart`，无 Key 时用 `markTestSkipped` 自动跳过。

3. **构建必须设的环境变量**（不设就是一堆莫名错误）：
   ```bash
   export JAVA_HOME="/e/dev/jdk-21.0.13+9"
   export ANDROID_HOME="/e/dev/android-sdk"
   export ANDROID_SDK_ROOT="$ANDROID_HOME"
   export PATH="$JAVA_HOME/bin:$PATH"
   export PUB_HOSTED_URL=https://pub.flutter-io.cn
   export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
   export PUB_CACHE=/e/dev/pub-cache      # 必须是 ASCII 路径，中文用户名会炸 jni 的 CMake
   ```
   - Flutter 在 `/e/dev/flutter/bin/flutter.bat`
   - 验证 APK 签名要用 **Windows 风格** `JAVA_HOME="E:/dev/jdk-21.0.13+9"`（MSYS 路径会报 invalid directory）
   - `android/settings.gradle.kts` 里有阿里云镜像，**不能加到 `build.gradle.kts` 的 allprojects**（prefer-settings-repositories 会报错）

4. **Gradle 9.5 移除了 `Project.exec()`。** 任何第三方 gradle 脚本用了它都会挂。需要时用 `project.services.get(org.gradle.process.ExecOperations)` 替代。

5. **LLM 输出分档不要用字数比例控制。** 按「允许出现哪些章节」的白名单控制详细度更稳，否则模型会靠凑字数或删干货达标。

6. **UI 组件不一定有你以为的参数。** `FloatingActionButton.extended` 就没有 `onLongPress`。想加"长按选模式"改成点击弹选择面板，可发现性也更好。

7. **长异步请求期间别把整页换成 spinner。** 会清掉其他 Tab 的编辑内容与滚动位置。用「保留页面 + 顶部 `LinearProgressIndicator` + 编辑区只读锁定」。

8. **`FloatingActionButton`/对话框返回后不要立刻 dispose controller。** `showDialog` 返回只是路由开始出栈，关闭动画期间 `TextField` 仍挂树上引用它们，会抛 `A TextEditingController was used after being disposed`。用 `addPostFrameCallback` 延后释放。

### 交付节奏（严格按顺序）

**第一阶段**：只读代码 + 输出改造清单
- 读 `lib/` 全部文件、`pubspec.yaml`、`db_service.dart` 的迁移逻辑
- 输出：五项能力各自的改造点清单、新增/修改的文件列表、数据库 schema 变更、风险点
- **不要写任何代码**。等用户确认。

**第二阶段**：模板整理（第 1 项）
- 实现模板系统 + 4 个内置模板 + 课程匹配 + 自定义存储
- 补测试（模板选择、提示词拼装、自定义模板往返）
- `flutter analyze` 零告警 + 全量测试通过 + 真实 API 验证两个模板产出结构不同
- 打包 APK 并验证签名

**第三阶段**：RAG 检索（第 2 项）
- FTS5 索引 + bigram 中文方案 + 全局搜索界面 + 跨笔记问答
- 索引一致性测试
- 同样完整验证后打包

**第四阶段**：LLM Wiki（第 3 项）
- 词条 schema + 增量抽取 + 冲突处理 + 浏览界面 + 与术语表打通
- 同样完整验证后打包

**第五阶段**：画布（第 4 项）
- 2D 画布 + 层次布局 + 手势 + 性能优化 + 导出
- 同样完整验证后打包

**第六阶段**：Skills（第 5 项）
- Skill 抽象 + 3 个内置技能 + 动态编排 + SkillProvider 预留
- 同样完整验证后打包

每阶段结束都要：
1. `flutter analyze` → `No issues found!`
2. `flutter test` → 全通过，跳过数等于预期
3. 有真实调用时单独跑 `test/real_api_*.dart` 并报出实测指标
4. `flutter build apk --release` → 核对体积 + `apksigner verify`
5. 复制到 `E:\Downloads\classnote-release.apk` 并告知用户
6. git 提交，commit message 写清本阶段主题

### 验收总标准

- 五项能力全部落地，每项都有可操作的界面入口（不是只有 API）
- 现有功能零回归：145 个已有测试全部继续通过
- 没有任何外部平台/框架依赖，全项目 grep 不到 `langchain` / `dify` / `n8n`
- `flutter analyze` 全程零告警
- 每一阶段都产出可安装的 APK，用户能立刻下载试用
- 关键逻辑都有测试覆盖，尤其是：索引一致性、模板往返、词条幂等、位置重算、开关真的生效（不要出现"关掉了但还在跑"的假开关）

### 最后一条要求

**每做完一阶段，停下来等用户确认再进下一阶段。** 不要一口气把五项都做完——用户需要边用边反馈，一次改太多既难验收也难回滚。