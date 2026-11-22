# 课堂图片辅助生成笔记 · DSH 实施提示词

> **怎么用**：新开一个 DSH 会话，从 `### 你是谁` 开始全选到文档末尾，整段发过去。
> 「一、背景」是给你看的，不用复制。

---

## 一、背景（给人看）

现在 classnote 的输入只有一条路：**录音 → 转写 → 纠错 → 总结**。但课堂上的信息不只在老师嘴里——板书的结构、PPT 的条目、教材上被翻到的那一页，往往是老师「照着讲」的东西，偏偏是录音里最残缺的部分（"看这里"、“这个表”、"书上第三节"）。

要做的是：**把课堂图片导进来，提取文字与结构，和录音转写合并成一份笔记**，并且让人能看出哪句话来自板书、哪句话来自老师原话。

三条必须写死的红线：

1. **图片里的字只许转写，不许补全。** 模糊、反光、被挡住的地方就写〔看不清〕，不许猜一个通顺的说法填进去。这条和教材检索的"章节号不许生成"是同一类问题：编造的内容会一路污染术语表、总结和 Wiki，而且用户很难发现。
2. **第一版不引入需要原生编译的依赖。** 这台机器上踩过 RNNoise 的坑（Gradle 9 移除了 `Project.exec`、缺 NDK 29、没有 Rust、Windows 开发者模式没开导致建不了 symlink）。所以不用 ML Kit / Tesseract 这类要编 native 的 OCR，先用**云端视觉模型走 HTTP**，纯 Dart。
3. **图片和识别结果留在本机。** 除了调用视觉模型那一次，不上传任何地方；界面上要写清楚"识别需要联网，图片会发到 xxx"，并且提供"只存不识别"。

---

## 二、任务提示词（复制下面这一段给 DSH）

### 你是谁

你是 classnote 这个 Flutter 课堂笔记 App 的开发者与唯一维护人。用户是林业专业学生，实际课程是植物学（方炎明主编《植物学》第三版，中国林业出版社）、建筑制图（第四版，东南大学出版社）、园林制图。

项目路径：`E:\Downloads\classnote`

### 当前代码现状（已核实，不要重新猜）

**目前完全没有图像能力。** `pubspec.yaml` 里没有 `image_picker` / `file_picker` / 任何 OCR 依赖；在 `lib/` 里搜 `image_picker|ImagePicker|ocr|Ocr|camera` 一个命中都没有。这是从零加一条输入通道。

**两个 Key，两条通道**（`lib/services/settings_service.dart:18-27`）：

| 设置项 | 用途 |
|---|---|
| `deepseek_api_key` | 总结、纠错、术语表、Wiki（`AppConfig.deepSeekBaseUrl`，纯文本 chat） |
| `siliconflow_asr_key` | 云端语音识别（`AppConfig.asrBaseUrl`，`/v1/audio/transcriptions`） |

`AiService.complete(system, user)` 是通用文本入口（`lib/services/ai_service.dart:444`），只发纯文本 messages —— **DeepSeek 这条通道不走图片**。硅基流动的接口是 OpenAI 兼容的（同一个 Key，`https://api.siliconflow.cn/v1/chat/completions`），视觉模型从这条通道接最省事。

**现有数据流**：

```
CloudAsrService → notes.transcript（唯一原文来源）
  → ClassroomAgent（纠错/总结/导图）
  → AiService.summarize(transcript, {level, courseName, template})   // ai_service.dart:535
  → StudySummary { detailMarkdown, mindMap, graph, pending, extras }  // study_note.dart:20-40
  → notes.summary_json 落库
```

超长课堂会分块：`AiService.chunkChars = 8000`（`ai_service.dart:51`），分块整理后再合并。

**笔记表**：`dbVersion = 9`，`notes` 有 `transcript / summary_json / terminology_json / course / template_id / textbook_id / chapter_no / chapter_title / section_no / section_title`。**没有图片字段。**

**详情页**：4 个 Tab —— 原文 / 详细笔记 / 思维导图 / 大纲（`note_detail_page.dart:541-544`）。没有图片 Tab。

**下游消费方**：
- 检索索引 `IndexDoc { noteId, title, course, transcript, summary }`（`search_index.dart:72`）
- Wiki 抽取输入 = 整理后的笔记 + 转写原文（`wiki_service.dart` 的 `_buildInput`）
- 术语表 `prepare(courseName, topic, material, knownTerms)`

### 硬约束

1. **不许编造板书内容。** 识别结果里每一个字都必须来自图片本身。
   看不清、被挡住、反光的地方写〔看不清〕，不许补成通顺的句子。
   这一条要**可验证**，不能只写在提示词里：模型必须按块输出，程序逐块检查（空块、纯标点、无意义的"以下是内容"一律丢弃）。
2. **第一版不引入原生编译依赖。** 用云端 VLM（视觉大模型）走 HTTP，纯 Dart。
   `image_picker` 是 Flutter 官方插件，可以用，但要先在真机上验证拍照/相册权限，别直接假定能跑。
3. **图片必须落在本机**，路径在应用私有目录里，删笔记时连带删图；不允许只存一个临时 URI。
4. **图片识别不阻塞录音。** 上课时用户可能一边录一边拍，识别是后台的、可失败的、可重试的。
5. **保留现有已跑通的功能。** 先读代码、列改造点，确认后再改。
6. 分阶段交付，每阶段 `flutter analyze` 零告警 + 全量测试通过 + 打包 APK + git 提交。

### 需求定义

#### 一、图片导入

**入口**（两处，都要）：
- 录音页：课程/位置选择器下方加「加课堂图片」按钮
- 笔记详情页：新增第 5 个 Tab「图片」

**来源**：拍照 / 从相册选（可多选，单次最多 9 张）。**图片类型**由用户选：`板书` / `PPT` / `教材页`——类型会写进提示词，影响提取方式（板书要保留层级，PPT 多条目，教材页要记页码）。

**落盘**：
```
<app documents>/note_photos/<noteId>/<timestamp>.jpg
```
用 `image_picker` 自带的 `maxWidth/maxHeight` 压到长边 1600、`imageQuality: 80`，不要把原图（10MB+）直接塞进去。图片目录要在笔记删除时一起删。

**界面**：缩略图网格，每张显示识别状态（未识别 / 识别中 / 成功 / 失败），点开看识别文本，长按或右上角删除。

#### 二、图片识别（VLM）

新增 `services/vision_service.dart`：

```dart
Future<PhotoOcrResult> recognize({
  required String imagePath,
  required PhotoKind kind,   // board / slide / textbook
  String courseName = '',
  String location = '',      // 复用 CourseLocation.chapterKey
});
```

**提示词要求模型输出 JSON**（不是一段自由文字）：

```json
{
  "blocks": [
    {"kind": "heading", "text": "第五章 被子植物"},
    {"kind": "bullet",  "text": "木兰科：花被片离生，雄蕊多数"},
    {"kind": "formula", "text": "..."},
    {"kind": "table",   "text": "| 科 | 特征 |\n|---|---|\n..."}
  ],
  "unreadable": ["左下角被同学挡住的一段"]
}
```

规则写死在提示词里：
- 只转写图片里**真实可见**的文字，一个字都不许补、不许润色、不许把口语改写成书面语
- 看不清 → 该块写〔看不清〕，并在 `unreadable` 里说明位置（左上/中间/右下）
- 公式用 LaTeX，表格用 Markdown 表格；板书层级（标题 / 一级条目 / 二级条目）要保留
- 不要输出"以下是从图片中提取的内容"这种开场白
- 如果整张图没有可读文字，返回空 `blocks`，不要硬凑

**程序侧校验**（这是防编造真正生效的地方）：
- `blocks` 必须非空才有意义；单块文字 < 2 字且不含数字/公式符号的直接丢
- 整张图识别结果为空 → 状态标「没有识别到文字」，不写库
- 记录用的模型名，方便以后换模型对比

**失败与重试**：网络失败/超时（90 秒）可重试一次；401/403 提示去设置检查 Key；余额不足（402）如实提示。

**落库（DB v10）**：

```sql
CREATE TABLE note_photos (
  id TEXT PRIMARY KEY,
  note_id TEXT NOT NULL,
  path TEXT NOT NULL,
  kind TEXT NOT NULL,          -- board / slide / textbook
  ocr_text TEXT,               -- 纯文本汇总
  ocr_json TEXT,               -- blocks 原始 JSON
  model TEXT,
  status TEXT NOT NULL,        -- pending / done / failed / empty
  error TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX idx_photo_note ON note_photos(note_id);
```

另外给 `notes` 加一列 `photo_text TEXT`：把所有图片的成功识别文本拼起来缓存一份。理由：总结、检索索引、Wiki 三个地方都要用，每次 JOIN 一遍图片表不划算，而且它天然是「这节课的补充材料」这个语义。

#### 三、合并生成笔记

**合并的定位要写清楚**：

| 来源 | 角色 | 在笔记里的处理 |
|---|---|---|
| 录音转写 | 主材料（时间轴、老师原话） | 保持现状 |
| 图片文字 | 补充材料（结构、条目、页码） | 按来源标记插入，不覆盖原话 |

**提示词注入**：总结提示词里加一段

```
## 课堂图片补充材料
以下是用户这节课拍的照片里识别出的文字。它可能与转写内容重复或互相矛盾：
- 与转写一致时，用它补全结构（板书的分层、表格、公式），不要重复一遍
- 与转写矛盾时，两处都保留，并在该处标〔说法不一：原文… / 板书…〕，不要自己挑一个
- 图片里出现的章节号、页码、公式编号，原样保留，不要推算
【板书】
...
【PPT】
...
【教材页】
...
```

**只导入图片、不录音也要能生成笔记**：`transcript` 为空时，用图片文本作为主体走同一条总结链路（`AiService.summarize` 要求 ≥10 字，这里要放开或另开入口，别用空字符串硬套）。

**详情页展示**：详细笔记里出现的板书内容带来源标记；「图片」Tab 能看到每张图 + 它的识别原文，识别错了可以手动改（改完重新生成笔记）。

#### 四、喂给下游

| 环节 | 怎么接 |
|---|---|
| 总结 | `summarize` 多一个 `photoText` 或 `supplementary` 参数，拼进提示词 |
| 检索索引 | `IndexDoc` 加 `photo` 字段，索引图片文字（权重低于原文，高于没有） |
| Wiki 抽取 | `_buildInput` 里加一节「课堂图片文字」 |
| 术语表 | 图片里的英文/缩写可以拼进 `knownTerms`（**可选，最后做**） |

### 技术判断与风险

1. **VLM 选型不能写死。** 硅基流动上可用的视觉模型名字经常变（Qwen2.5-VL 系列、InternVL 等都有过），**模型名必须进设置页可配置**，代码里只给一个默认值，真机跑通之前不要在任何地方承诺"用 XX 模型"。文档里提到的模型名一律以控制台当时实际可用的为准。
2. **中文手写板书的识别质量是个未知数**，不要假装确定。先拍 3 类样张实测：
   - 黑板粉笔（最容易失败：对比度低、反光、透视）
   - 白板马克笔（中等）
   - PPT 投影（通常最好）
   实测结果决定产品形态：如果手写确实不行，就只承诺"PPT / 打印体"，手写图片照样能存、能识别，但界面上提示「手写识别可能不准，建议人工校对」。
3. **图片压缩是成本控制的关键。** 1600 长边的图比原图省一个数量级的 token；不要为了"更准"传原图。
4. **透视与反光没法靠提示词解决。** 不做图像矫正（那要有原生 CV 或算法库），提示词里要求模型"按视觉分栏输出"，别要求它还原坐标。
5. **隐私要说清楚。** 图片会发到第三方视觉模型服务；界面上第一次识别时弹一次说明，设置里留开关「识别时上传图片（关闭后只保存不识别）」。
6. **删除语义**：删图片时，识别文本要不要一起删？建议**删图保留文字**，但把该图的贡献从 `notes.photo_text` 里移除，并在笔记里标注「来源图片已删除」。反过来会让笔记突然缺一块。
7. **不碰录音链路。** `CloudAsrService`、`RecordPage` 的录音状态机、草稿自动保存都是验证过的，图片只是并行的一条输入，别改它们的行为。

### 交付节奏

**第一阶段：只读代码 + 输出改造清单，不写代码**
- 读 `pubspec.yaml`、`db_service.dart`、`note.dart`、`ai_service.dart`、`note_detail_page.dart`、`record_page.dart`、`indexdoc/search_index.dart`、`wiki_service.dart`
- 输出：DB 变更、服务拆分、界面改动点、提示词注入点、风险清单、待拍板问题
- 停下等确认

**第二阶段：图片导入与本地存储（DB v10）**
- `image_picker` 接入（先真机验证权限与压缩）
- `services/photo_service.dart`：选图、压缩、落盘、列表、删除、级联删
- `note_photos` 表 + `notes.photo_text` 列
- 详情页「图片」Tab（网格 + 空态）+ 录音页入口
- 测试：路径与级联删除、压缩尺寸、EXIF 旋转
- analyze 零告警 + 全量测试 + 打包

**第三阶段：图片识别**
- `services/vision_service.dart`（OpenAI 兼容请求，Key 复用 `siliconflow_asr_key`）
- 设置页：视觉模型名、上传开关
- 识别状态机（pending/done/failed/empty）+ 重试
- 测试：JSON 块校验（空块/废话块被丢弃）、无文字图片返回空、异常分支
- 真机实测三类样张，把结论写进文档
- analyze + 全量测试 + 打包

**第四阶段：合并生成笔记**
- 总结提示词注入图片材料（带来源与冲突规则）
- 纯图片笔记路径
- 详情页展示来源标记、识别原文可改
- 测试：提示词里真的带上了图片文本、纯图片路径可生成、冲突标记不被模型吞掉
- analyze + 全量测试 + 打包

**第五阶段：下游**
- 检索索引加图片文字
- Wiki 抽取输入加图片文字
- 术语 knownTerms（可选）
- analyze + 全量测试 + 打包

### 验收标准

- 拍一张 PPT，能转出条目列表；黑板照片里模糊的地方出现〔看不清〕，而不是编出一句通顺的话
- 同一节课：1 段录音 + 3 张图片，生成的笔记里板书内容出现在对应章节，并带来源标记
- 只导入图片、不录音，也能生成一份像样的笔记
- 图片删掉后，笔记里那段文字还在，但标注「来源图片已删除」
- 关闭「上传图片」开关后，选图只保存不识别，界面明确显示「未识别」
- 老笔记（没有图片）打开不报错、不显示空网格
- 现有 371 个测试继续全部通过，`flutter analyze` 全程零告警

### 最后一条

每阶段做完停下等用户确认再继续。这个功能涉及外部模型服务（钱、隐私、质量都不确定），一次改太多既难验收也难回滚。

---

## 三、需要你拍板的几个问题

复制提示词之前，这几条最好先定下来，不然 DSH 会来问你：

1. **图片类型**：让用户手选「板书 / PPT / 教材页」，还是让模型自动判断？我建议手选——自动判断错了，提取方式就跟着错，而且用户看不出来。
2. **手写识别不达标时怎么办**：只承诺 PPT / 打印体，还是手写照做但强制提示人工校对？前者诚实，后者覆盖全但体验容易崩。
3. **纯图片笔记**要不要第一版就做？还是强制「必须有录音或至少打一段字」？
4. **删除图片后文字保留**（我的建议）还是连带清掉？
5. **单次张数上限**：9 张是我拍的，按你会一次拍多少定；张数直接影响一次处理的钱。
6. **用哪个视觉服务**：复用硅基流动的 Key（最省事，接口已经是 OpenAI 兼容），还是另开一家？如果另开，设置页就要多一组 Key。

---

## 四、一句话总结这个功能的价值

录音解决"老师说了什么"，图片解决"老师指的是什么"。两边合起来，笔记才不是一段脱水的文字，而是能对回课堂现场的东西。