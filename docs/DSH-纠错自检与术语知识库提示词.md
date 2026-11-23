# 纠错自检 + 术语知识库闭环 · DSH 实施提示词

> 新开一个 DSH 会话，从 `### 你是谁` 开始整段复制发送。
> 本文把需求里五个「待补充」都定了默认值，理由写在每节后面；不同意就改那一条再发。

---

## 〇、五个待补充的默认答案（先看这个）

| 待补充 | 默认答案 |
|---|---|
| 专家领域范围 | 「课堂术语复核员」：只判断**术语/专名/同音替换**是否成立，以及术语知识本身是否自洽。不评价总结质量、不改写句子、不做翻译 |
| 知识库存储与更新 | **复用现有 `wiki_entries` / `wiki_sources`**（已有 variants、status=pending/confirmed）；新增 `term_revisions` 表记录每次改动；自检发现的知识错误先入表待确认，不直接覆盖 |
| 自检结果呈现 | 报告新增「知识复核」区：逐条给 `采纳 / 不采纳 / 存疑` + 依据（原文上下文 + 知识库条目）+ 置信度（高/中/低）；知识库页给存疑词条打标 |
| 一键优化作用范围 | 默认**两者都改**（本次纠错结果 + 知识库），两个开关可分别关掉；只应用「采纳且置信度≥中」的项；存疑项不动；全部改动写 revision，可一键回滚 |
| 触发时机 | 一键处理/校准成功后**自动跑一次**（设置可关，默认开），失败不阻塞主流程；详情页有「重新复核」，知识库页有「全课体检」 |

---

## 一、你是谁

你是 classnote（Flutter 课堂笔记 App，路径 `E:\Downloads\classnote`）的开发者。当前版本 v1.5.2，已有：

- 术语表生成（`terminology_service.dart`，15~25 条，每条带 `misheardList`）
- 转写校准（`transcript_corrector.dart`，A/B/C 三档，待确认预算 5 条）
- 纠错 Agent（`correction_agent.dart`，`lookup_terminology` / `flag_uncertain`）
- 术语知识库（`wiki_service.dart` + `wiki_entries` / `wiki_sources`，词条有 variants 与 pending/confirmed 状态，`variantsOfCourse` 已喂给纠错 Agent）
- 待确认处理（`pending_fixer.dart`，单条替换后重算位置）

现在要加的是**纠错之后的一层知识性自检**：让一个「术语复核员」Agent 回看纠错结果，判断每条替换到底成不成立，并把结论反哺给知识库。

## 二、必须守住的红线

1. **自检只给结论，不直接改正文**。正文改动只能由用户点「一键优化」或逐条采纳触发。
2. **不确定就写「存疑」**，不许猜。存疑项不得进一键优化。
3. **知识库改动可回滚**。每次写库前存 `term_revisions`（before/after 完整快照 + 原因 + 时间）。
4. **不越界**：不评价总结、不润色、不翻译、不补原文没有的内容。
5. **失败不阻塞**：自检超时或 JSON 解析失败时，纠错结果照常展示，报告里标「复核未完成」。
6. **可追溯**：每条结论必须带证据（原文片段 + 术语表/知识库引用），没有证据的结论一律降为「存疑」。

## 三、数据模型（dbVersion 10 → 11）

```sql
-- 自检结论（挂在一次校准/一份笔记上）
CREATE TABLE IF NOT EXISTS review_findings (
  id TEXT PRIMARY KEY,
  note_id TEXT NOT NULL,
  kind TEXT NOT NULL,            -- replace / miss / kb_issue
  span TEXT NOT NULL,            -- 原文片段
  current TEXT NOT NULL,         -- 纠错后的写法
  suggestion TEXT NOT NULL,      -- 建议写法（可为空）
  verdict TEXT NOT NULL,         -- adopt / reject / unsure
  confidence REAL NOT NULL,      -- 0~1
  evidence TEXT NOT NULL,        -- JSON：上下文引用 + 知识库条目 id + 理由
  applied INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);

-- 知识库改动记录（可回滚）
CREATE TABLE IF NOT EXISTS term_revisions (
  id TEXT PRIMARY KEY,
  entry_id TEXT,                 -- 可为空：新增词条时先空
  action TEXT NOT NULL,          -- add / update_variants / update_term / deprecate
  before_json TEXT NOT NULL,
  after_json TEXT NOT NULL,
  reason TEXT NOT NULL,
  source_finding_id TEXT,
  undone INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);
```

`wiki_entries` 增加一列 `suspect_reason TEXT`（自检认为该词条有误/存疑时的说明），迁移用 `ALTER TABLE ... ADD COLUMN`，老库缺列当空串。

## 四、复核 Agent 的契约

### 输入（程序拼好，模型不自己找）

- 纠错后正文（annotatedText 去掉〔…〕标注的版本）与原文
- 本次 `hits`（术语命中/修正记录）
- 本次 `pending`（剩余待确认）
- 本节术语包（term / misheard / definition）
- 知识库中本课程相关词条（term + variants + definition + status），带上条数上限 40

### 输出（严格 JSON，不要多余文字）

```json
{
  "findings": [
    {
      "kind": "replace",
      "span": "木兰棵",
      "current": "木兰科",
      "suggestion": "木兰科",
      "verdict": "adopt",
      "confidence": 0.92,
      "evidence": "前句“木兰科植物…”与教材第五章一致；知识库条目 w_1024 记有该误听形式",
      "kb_ref": "w_1024"
    }
  ],
  "kbIssues": [
    {
      "term": "木兰科",
      "issue": "variants 里把‘木兰颗’当误听，实际课堂更常见‘木兰棵’，建议替换",
      "verdict": "unsure",
      "confidence": 0.6,
      "evidence": "本节 3 次出现均为‘木兰棵’"
    }
  ],
  "summary": "一句话：本次 4 条替换中 3 条成立、1 条存疑；知识库有 1 处变体写反"
}
```

判定规则（写进系统提示词）：

- **adopt**：上下文能支撑该替换，且没有更强反证；
- **reject**：替换违背上下文或术语知识（例如把“心皮”改成“心脾”），必须给反证；
- **unsure**：证据不足、或两可，一律走这里，**不许硬选**。
- 置信度 < 0.6 自动降为 unsure。
- `kbIssues` 只报「知识库本身可能错」的条目，最多 5 条。

## 五、流程

```
一键处理 / 校准完成
   └─→ 写报告（现有）
   └─→ 触发 ReviewAgent（可关）
         ├─ findings 落库 review_findings（applied=0）
         ├─ kbIssues 先在知识库页标「存疑」，不覆写
         └─ 报告新增「知识复核」区
               ├─ 逐条：采纳 / 不采纳 / 存疑 + 依据 + 置信度
               ├─ 每条可单独「采纳」「忽略」
               └─ 「一键优化」：应用所有 adopt 项
                     ├─ 改正文（复用 PendingFixer，逐条重算位置）
                     ├─ 改知识库（写 term_revisions + 更新 wiki_entries）
                     └─ 生成一条可回滚的 revision 批次
```

### 一键优化的作用范围

- 面板上两个开关：**修正正文**（默认开）、**更新知识库**（默认开）；
- 只处理 `verdict == adopt` 且 `confidence >= 0.6`；
- 存疑/不采纳不动；
- 执行前显示「将修改 N 处正文、M 条词条」，二次确认；
- 执行后给「撤销本次优化」，按 revision 批次回滚（正文与知识库一起回）。

## 六、界面

### 详情页「知识复核」区

```
知识复核 · 4 条
✓ 木兰棵 → 木兰科   置信 0.92   依据：教材第五章、知识库 w_1024
   [采纳] [忽略]
? 心脾 → 心皮       置信 0.55   依据不足：本节只出现一次  [存疑]
✗ 木兰花 → 木兰科   置信 0.80   反证：后文明确说“木兰花是另一种”  [不采纳]
[一键优化（3 条）]
```

- 默认折叠，标题显示条数；点开后最多展示 5 条，其余折叠；
- 每条「依据」可展开看完整引用；
- 存疑项用灰色，不提供「采纳」。

### 知识库页

- 词条列表加「存疑」标记（`suspect_reason` 非空）；
- 词条详情显示最近 5 条 revision，可单条回滚；
- 「全课体检」按钮：对本课程全部词条跑一次 kbIssues 检查，结果同样进复核区。

## 七、提示词（可直接用）

系统提示词要点：

```
你是课堂术语复核员。你的唯一职责是：判断一次 AI 纠错里的术语替换是否成立，
以及术语知识库里的条目是否与课堂语境一致。你不改写句子、不评价总结、不翻译。

判定只允许三种：adopt / reject / unsure。
- adopt：上下文与术语知识都支持该写法；
- reject：上下文或术语知识明确反对，必须给出原文中的反证；
- unsure：证据不足或两可，一律选这个，不许硬选。
置信度 < 0.6 的一律按 unsure 处理。

每条结论必须带 evidence：引用原文里的具体片段（不超过 40 字），
或引用知识库条目 id 与其 variants。没有证据的结论无效。

kbIssues 只报「知识库本身可能写错」的条目，最多 5 条，同样要给依据。
```

## 八、验收

1. 固定样例：构造 6 条替换（3 对 3 错 1 存疑），复核结论与人工判定一致率 ≥ 4/6；
2. 自检超时/坏 JSON 时，报告仍显示，标题标「复核未完成」；
3. 「一键优化」只动 adopt 项，存疑项原样保留；
4. 优化后「撤销」能把正文与知识库同时恢复到优化前（逐字段比对）；
5. 知识库被改动后，`variantsOfCourse` 的输出随之变化（下节课纠错能用上新变体）；
6. 迁移：v10 老库升级到 v11 不丢数据，`suspect_reason` 缺列当空串；
7. `flutter analyze --no-pub` 0 告警，全量测试通过。

## 九、分阶段

1. **只读设计确认**：读 `wiki_service.dart` / `transcript_corrector.dart` / `note_detail_page.dart`，给出接入点与迁移方案，停下等确认；
2. **模型与表**：`review_findings`、`term_revisions`、`wiki_entries.suspect_reason`，迁移测试；
3. **ReviewAgent**：提示词 + JSON 解析 + 超时降级，单测（假 AI）；
4. **界面**：详情页复核区 + 知识库存疑标记；
5. **一键优化 + 回滚**：正文与知识库联动，revision 批次撤销；
6. **真机验证**：跑一节真课，记录采纳率、误报率。

## 十、风险

| 风险 | 处理 |
|---|---|
| 复核 Agent 自己也开始「猜」 | 强制 evidence + 置信度阈值，没证据降 unsure |
| 一键优化把知识库改坏 | 全部走 revision，可回滚；知识库改动默认只加 variants，不改 term 本身 |
| 成本翻倍（每节课多一次 LLM） | 复核只喂「hits + pending + 术语包」，不喂全文；超 8000 字截断，按条计费约多 0.02 元/节 |
| 老库迁移失败 | 迁移前 `PRAGMA user_version` 检查，失败保留原库并提示备份 |