# 学科专家质检（Academic Review）· 实施说明

> 这版取代了之前「课堂术语复核员」的定位：用户要的是**学科专家**，检查笔记里的知识是否符合科学事实，不只是判断替换成不成立。
> 旧的术语复核方案仍保留在 `DSH-纠错自检与术语知识库提示词.md`，作为「知识库反查」的后续扩展，不在本版范围。

## 一、做了什么（v1.6.0）

| 层 | 实现 |
|---|---|
| 模型 | `lib/models/academic_review.dart`：`SubjectCode`（botany / computer_science / law / general）、`AcademicReview`、硬伤 / 逻辑漏洞 / 术语正名三类条目，JSON 双向兼容 snake_case 与 camelCase |
| 服务 | `lib/services/academic_review_service.dart`：`route()` 先判学科（只看前 800 字，`max_tokens=200`），`review()` 交给学科专家（正文上限 8000 字，`max_tokens=3000`） |
| 存储 | `dbVersion` 10→11，新增 `academic_reviews(note_id PK, subject, result_json, created_at)`，一篇笔记一份，重跑覆盖 |
| 界面 | 笔记详情 AppBar 新增 🎓「学科质检」；跑完弹底部面板：硬伤（红）/ 表述不严谨（橙）/ 术语正名（可逐条「替换」，全部替换并可撤销）/ 复习建议（绿）；原文页顶部常驻「上次学科质检：N 处问题 · 查看」 |

## 二、为什么分两跳

路由与质检拆成两次调用：

- 路由只喂 800 字、200 token，成本约 0.0005 元，判错也只损失这一点；
- 质检才喂 8000 字、3000 token，约 0.01~0.02 元。

一次调用同时做「判学科 + 质检」也能跑，但模型会为了自圆其说把笔记硬塞进某个学科。分开之后，路由置信度 < 0.35 直接转 `general`，不硬判。

## 三、学科规则库

`AcademicReviewService.subjects` 里每个学科一条 `rules` 文本，直接拼进专家提示词：

- **botany**：茎变态 vs 叶变态、茎卷须/叶卷须/托叶卷须、同功不同源、芋头是球茎、佛焰苞、捕虫叶触发 vs 消化、地下变态茎的三重适应意义。
- **computer_science**：复杂度、数据结构定义、代码逻辑漏洞、OS 概念（进程/线程、死锁四条件）。
- **law**：法条编号与内容对应、主体/客体、构成要件、程序顺序；只做知识核对，不出法律意见。
- **general**：循环定义、分类标准混用、相关当因果、数据缺单位、类比当论证。

新增学科只需：`SubjectCode` 加枚举值 → `subjects` 加一条规则 → 路由提示词加一行代码。

## 四、JSON 契约

模型输出（提示词里已固定）：

```json
{
  "agent_name": "植物学质检官",
  "summary": "发现 2 处硬伤，3 处表述不严谨",
  "hard_errors": [{"id":1,"error_type":"分类归属错误","original_text":"…","reason":"…","suggestion":"…"}],
  "logic_flaws": [{"id":1,"original_text":"…","reason":"…","suggestion":"…"}],
  "term_corrections": [{"wrong":"…","correct":"…","reason":"…"}]
}
```

程序侧清洗（不是模型自觉）：

- `original_text` 为空 → 丢弃（定位不到就没有展示价值）；
- `term_corrections` 里 `wrong == correct` → 丢弃；
- 置信度不用模型自报，靠路由置信度 + 人工采纳；质检条目不写「置信度」字段，避免伪精确。

## 五、边界与红线

1. **只出结论，不改正文**。术语替换必须点「替换」并二次确认；正文改动走 `PendingFixer`，可撤销。
2. **找不到原文就不报**。提示词要求 `original_text` 原样出现；程序侧只校验非空，不强行定位。
3. **不越界**：不评价排版、不改写段落、不提供法律意见。
4. **失败不降级成假结果**：网络/解析失败直接提示，不返回「看起来像质检」的空壳。
5. **成本可见**：结果面板底部写明「基于笔记文本与学科常识，不替代教材和老师」。

## 六、验证

- `flutter analyze --no-pub`：0 告警
- `flutter test --no-pub`：**447 通过 + 29 跳过**（新增 9 例：路由围栏 JSON/未知学科/低置信/坏 JSON、三类结果解析与清洗、默认路由、空正文、模型往返）
- **未做**：没有 DeepSeek Key，真实调用没跑；真机未验证面板渲染。

## 七、下一步（可选）

1. 把「术语正名」与现有 `wiki_entries.variants` 联动：替换成功后把 `wrong` 写进对应词条的 variants，下节课纠错直接用上。
2. 质检结果按 `hard_errors` 数量排序、支持「只看硬伤」筛选。
3. 路由缓存：同一笔记第二次质检不再重复路由。