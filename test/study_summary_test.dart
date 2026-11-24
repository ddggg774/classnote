// test/study_summary_test.dart
// 详细笔记的解析与兼容性测试。
// 重点保证三件事：
//   ① 模型输出「Markdown 正文 + 末尾 json 代码块」时能正确拆开（历史行为）；
//   ② 老数据（只有 mindMap、没有 detail）解析不崩，正文为空；
//   ③ 坏数据降级为 null 而不是抛异常。
import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/models/mind_graph.dart';
import 'package:classnote/models/study_note.dart';
import 'package:classnote/models/terminology.dart';
import 'package:classnote/services/ai_service.dart';

void main() {
  final service = AiService();

  group('解析模型输出', () {
    test('能从 Markdown 正文里剥出末尾的 json 导图', () {
      const raw = '''
# 课程信息
- 课程名：高等数学

# 知识点结构
## 极限的定义
说明文字。

```json
{"root":"高等数学","nodes":[{"topic":"极限","children":["定义","性质"]}]}
```
''';
      final s = service.debugParseSummary(raw);
      expect(s.detailMarkdown, contains('# 课程信息'));
      expect(s.detailMarkdown, contains('## 极限的定义'));
      // json 块不应残留在正文里
      expect(s.detailMarkdown, isNot(contains('"nodes"')));
    });

    test('外层包了 ```markdown 围栏也能剥掉', () {
      const raw = '''
```markdown
# 课程信息
本节讲导数。

```json
{"root":"导数","nodes":[]}
```
```
''';
      final s = service.debugParseSummary(raw);
      expect(s.detailMarkdown, startsWith('# 课程信息'));
      expect(s.detailMarkdown, isNot(contains('```markdown')));
      expect(s.graph.branches, isEmpty);
    });

    test('只有 Markdown、没有 json 时导图给空壳而不是报错', () {
      const raw = '# 课程信息\n- 课程名：线性代数';
      final s = service.debugParseSummary(raw);
      expect(s.detailMarkdown, contains('线性代数'));
      expect(s.graph.branches, isEmpty);
    });

    test('json 内容坏了不影响正文', () {
      const raw = '''
# 课程信息
正文照常。

```json
{"root": 这里是坏的 JSON
```
''';
      final s = service.debugParseSummary(raw);
      expect(s.detailMarkdown, contains('正文照常'));
    });

    test('整篇只有 JSON 没有正文时抛异常，避免清空已有笔记', () {
      const raw = '{"root":"旧格式","nodes":[{"topic":"a","children":["b"]}]}';
      expect(() => service.debugParseSummary(raw), throwsA(isA<AiException>()));
    });

    test('完全空的 Markdown 抛异常而不是返回空文档', () {
      expect(() => service.debugParseSummary(''), throwsA(isA<AiException>()));
    });
  });

  group('StudySummary 序列化兼容', () {
    test('新格式 encode/decode 往返一致', () {
      const raw = '''
# 课程信息
内容

```json
{"root":"主题","nodes":[{"topic":"t","children":["c"]}]}
```
''';
      final s = service.debugParseSummary(raw);
      final restored = StudySummary.tryDecode(s.encode())!;
      expect(restored.detailMarkdown, s.detailMarkdown);
      expect(restored.hasDetail, isTrue);
    });

    test('老数据（只有 mindMap 结构）解析不崩、正文为空', () {
      const legacy =
          '{"root":"老笔记","nodes":[{"topic":"要点","children":["子点"]}]}';
      final restored = StudySummary.tryDecode(legacy)!;
      // 老数据没有详细正文，页面应提示重新生成
      expect(restored.hasDetail, isFalse);
    });

    test('坏数据返回 null 而不是抛异常', () {
      expect(StudySummary.tryDecode('not json at all'), isNull);
      expect(StudySummary.tryDecode(''), isNull);
      expect(StudySummary.tryDecode(null), isNull);
    });
  });

  group('分块逻辑（回归）', () {
    test('长文本仍然能分块且不丢内容', () {
      final text = '课堂内容。' * 5000;
      final chunks = service.debugSplitText(text);
      expect(chunks.length, greaterThan(1));
      expect(chunks.last.endsWith('。'), isTrue);
    });

    test('空文本返回空列表', () {
      expect(service.debugSplitText(''), isEmpty);
    });
  });

  _pendingPersistenceTests();
}// ─────────────────────────────────────────────────────────────
// 待确认项随总结一起持久化（Agent 跑完 → 落库 → 详情页读出来可点）
// 这块最容易出「存进去了但读不出来」，必须做往返验证。
// ─────────────────────────────────────────────────────────────
void _pendingPersistenceTests() {
  group('待确认项持久化', () {
    StudySummary base({List<PendingItem> pending = const []}) => StudySummary(
          detailMarkdown: '# 标题\n正文',
          graph: MindGraph.fromJson({
            'root': '木兰科',
            'branches': [
              {'id': 'b0', 'title': '知识点结构', 'children': []}
            ],
          }),
          pending: pending,
        );

    test('往返后片段、候选、次数、位置都还在', () {
      final original = base(pending: const [
        PendingItem(
          snippet: '心脾',
          candidates: ['心皮'],
          count: 2,
          positions: [7, 14],
        ),
      ]);
      final decoded = StudySummary.tryDecode(original.encode());
      expect(decoded, isNotNull);
      final p = decoded!.pending.single;
      expect(p.snippet, '心脾');
      expect(p.candidates, ['心皮']);
      expect(p.count, 2);
      expect(p.positions, [7, 14]);
      expect(p.canLocate, isTrue);
      expect(p.firstPosition, 7);
    });

    test('没有待确认项时不写这个字段，也不影响解码', () {
      final json = base().encode();
      expect(json.contains('pending'), isFalse,
          reason: '空列表不该占用存储');
      final decoded = StudySummary.tryDecode(json);
      expect(decoded!.pending, isEmpty);
    });

    test('老数据（没有 pending 字段）能正常解码', () {
      // 模拟旧版本存下来的 JSON
      const old = '{"format":"classnote.detail.v2","detail":"老的正文",'
          '"mindMap":{"root":"主题","nodes":[]},'
          '"graph":{"root":"主题","branches":[]},"chunked":false}';
      final decoded = StudySummary.tryDecode(old);
      expect(decoded, isNotNull);
      expect(decoded!.detailMarkdown, '老的正文');
      expect(decoded.pending, isEmpty,
          reason: '老数据没有待确认项，应降级为空而不是崩');
    });

    test('坏数据里的 pending 不影响整体解析', () {
      const dirty = '{"format":"classnote.detail.v2","detail":"正文",'
          '"mindMap":{"root":"x","nodes":[]},'
          '"graph":{"root":"x","branches":[]},'
          '"pending":[{"snippet":"心脾"},{"没有snippet字段":true}]}';
      final decoded = StudySummary.tryDecode(dirty);
      expect(decoded, isNotNull);
      // 第一个正常读出来，第二个缺字段降级成空片段
      expect(decoded!.pending.length, 2);
      expect(decoded.pending[0].snippet, '心脾');
      expect(decoded.pending[1].snippet, '');
    });

    test('清除待确认后重新编码，其他内容不变', () {
      final withPending = base(pending: const [PendingItem(snippet: '心脾')]);
      final cleared = StudySummary(
        detailMarkdown: withPending.detailMarkdown,
        graph: withPending.graph,
        chunked: withPending.chunked,
        pending: const [],
      );
      final decoded = StudySummary.tryDecode(cleared.encode());
      expect(decoded!.pending, isEmpty);
      expect(decoded.detailMarkdown, withPending.detailMarkdown);
      expect(decoded.graph.branches.length, withPending.graph.branches.length);
    });
  });
}
