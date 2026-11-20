// test/study_summary_test.dart
// 详细笔记的解析与兼容性测试。
// 重点保证三件事：
//   ① 模型输出「Markdown 正文 + 末尾 json 代码块」时能正确拆开；
//   ② 老数据（只有 mindMap、没有 detail）升级后不会崩、不会丢导图；
//   ③ 坏数据降级为 null 而不是抛异常。
import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/models/study_note.dart';
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
      expect(s.mindMap.root, '高等数学');
      expect(s.mindMap.nodes.length, 1);
      expect(s.mindMap.nodes.first.children.length, 2);
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
      expect(s.mindMap.root, '导数');
    });

    test('只有 Markdown、没有 json 时导图给空壳而不是报错', () {
      const raw = '# 课程信息\n- 课程名：线性代数';
      final s = service.debugParseSummary(raw);
      expect(s.detailMarkdown, contains('线性代数'));
      expect(s.mindMap.nodes, isEmpty);
      expect(s.mindMap.root, isNotEmpty);
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
      expect(s.mindMap.nodes, isEmpty);
    });

    test('整篇就是纯 JSON（旧版行为）也能识别', () {
      const raw = '{"root":"旧格式","nodes":[{"topic":"a","children":["b"]}]}';
      final s = service.debugParseSummary(raw);
      expect(s.mindMap.root, '旧格式');
      expect(s.mindMap.nodes.length, 1);
      expect(s.detailMarkdown, isEmpty);
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
      expect(restored.mindMap.root, '主题');
      expect(restored.hasDetail, isTrue);
    });

    test('老数据（只有 mindMap 结构）仍能读出导图', () {
      const legacy =
          '{"root":"老笔记","nodes":[{"topic":"要点","children":["子点"]}]}';
      final restored = StudySummary.tryDecode(legacy)!;
      expect(restored.mindMap.root, '老笔记');
      expect(restored.mindMap.nodes.length, 1);
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
}