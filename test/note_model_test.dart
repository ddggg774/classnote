// test/note_model_test.dart
// 纯 Dart 测试：笔记模型的序列化与 copyWith 语义。
// 重点是 copyWith 的「清空总结」和「向后兼容老库缺列」这两条，
// 它们都是本次改动里容易回归的地方。
import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/models/note.dart';

void main() {
  group('Note 序列化', () {
    test('toMap / fromMap 往返一致', () {
      final note = Note(
        id: 'abc',
        title: '高数第三讲',
        transcript: '这是转写内容',
        summaryJson: '{"root":"测试","nodes":[]}',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        duration: 3600,
        status: Note.statusDone,
      );
      final restored = Note.fromMap(note.toMap());
      expect(restored.id, note.id);
      expect(restored.title, note.title);
      expect(restored.transcript, note.transcript);
      expect(restored.summaryJson, note.summaryJson);
      expect(restored.duration, 3600);
      expect(restored.status, Note.statusDone);
      expect(restored.createdAt.millisecondsSinceEpoch, 1700000000000);
    });

    test('老库没有 status 列时兜底为已完成', () {
      // 模拟 v1 版本的数据库行：完全没有 status 字段
      final legacyRow = <String, dynamic>{
        'id': 'old',
        'title': '旧笔记',
        'transcript': '旧内容',
        'summary_json': null,
        'created_at': 1700000000000,
        'duration': 100,
      };
      final note = Note.fromMap(legacyRow);
      expect(note.status, Note.statusDone);
      expect(note.isDraft, isFalse);
    });

    test('草稿标记可被识别', () {
      final draft = Note(
        id: 'd1',
        title: '未命名课堂',
        transcript: '',
        createdAt: DateTime.now(),
        status: Note.statusDraft,
      );
      expect(draft.isDraft, isTrue);
    });
  });

  group('Note.copyWith', () {
    final base = Note(
      id: 'n1',
      title: '原标题',
      transcript: '原内容',
      summaryJson: '{"root":"旧总结","nodes":[]}',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      duration: 10,
    );

    test('不传参数时字段保持不变', () {
      final copy = base.copyWith();
      expect(copy.title, '原标题');
      expect(copy.transcript, '原内容');
      expect(copy.summaryJson, base.summaryJson);
      expect(copy.duration, 10);
    });

    test('update 单个字段不影响其他字段', () {
      final copy = base.copyWith(transcript: '新内容');
      expect(copy.transcript, '新内容');
      expect(copy.summaryJson, base.summaryJson); // 总结不能被顺带清掉
      expect(copy.title, '原标题');
    });

    test('clearSummary 能真正把总结清空（旧版做不到）', () {
      final copy = base.copyWith(clearSummary: true);
      expect(copy.summaryJson, isNull);
      expect(copy.hasSummary, isFalse);
      // 其余字段不受影响
      expect(copy.transcript, '原内容');
    });

    test('可以同时更新标题、正文、时长和状态', () {
      final copy = base.copyWith(
        title: '新标题',
        transcript: '新正文',
        duration: 99,
        status: Note.statusDone,
      );
      expect(copy.title, '新标题');
      expect(copy.transcript, '新正文');
      expect(copy.duration, 99);
      expect(copy.status, Note.statusDone);
    });
  });

  group('MindMapData 解析', () {
    test('正常 JSON 能解析出节点', () {
      final data = MindMapData.fromJson({
        'root': '高数',
        'nodes': [
          {
            'topic': '极限',
            'children': ['定义', '性质']
          },
        ],
      });
      expect(data.root, '高数');
      expect(data.nodes.length, 1);
      expect(data.nodes.first.topic, '极限');
      expect(data.nodes.first.children.length, 2);
    });

    test('缺字段时给默认值而不是抛异常', () {
      final data = MindMapData.fromJson({});
      expect(data.root, '本课总结');
      expect(data.nodes, isEmpty);
    });

    test('节点缺 children 时为空列表', () {
      final data = MindMapData.fromJson({
        'root': 'x',
        'nodes': [
          {'topic': 'y'}
        ],
      });
      expect(data.nodes.first.children, isEmpty);
    });
  });
}
