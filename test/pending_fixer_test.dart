// test/pending_fixer_test.dart
// 待确认项一键替换的测试。
//
// 这里盯的是三个真会出事的地方：
//   ① 同一片段多次出现：全替 / 只替一处 都要对
//   ② 替换后长度变了，**其余待确认项的位置必须重算**
//      —— 不重算，用户点第二条就跳到错的位置
//   ③ 替换失败时不能说"成功"
import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/models/terminology.dart';
import 'package:classnote/services/pending_fixer.dart';

void main() {
  group('单处替换', () {
    test('只替第一处，其余保持原文', () {
      const text = '心脾很重要，心脾还要再讲一次。';
      const item = PendingItem(snippet: '心脾', candidates: ['心皮']);
      final r = PendingFixer.apply(text, item, '心皮');
      expect(r.replaced, 1);
      expect(r.text, '心皮很重要，心脾还要再讲一次。');
    });

    test('替在结尾也能正确拼接', () {
      const text = '最后讲的是心脾';
      const item = PendingItem(snippet: '心脾');
      final r = PendingFixer.apply(text, item, '心皮');
      expect(r.text, '最后讲的是心皮');
    });

    test('替在开头能正确拼接', () {
      const text = '心脾是重点';
      const item = PendingItem(snippet: '心脾');
      final r = PendingFixer.apply(text, item, '心皮');
      expect(r.text, '心皮是重点');
    });
  });

  group('全部替换', () {
    test('all=true 时替换所有出现', () {
      const text = '心脾很重要，心脾还要再讲一次，心脾是考点。';
      const item = PendingItem(snippet: '心脾');
      final r = PendingFixer.apply(text, item, '心皮', all: true);
      expect(r.replaced, 3);
      expect(r.text.contains('心脾'), isFalse);
      expect('心皮'.allMatches(r.text).length, 3);
    });

    test('替换成更长的词，后续内容不乱', () {
      const text = '甲心脾乙';
      const item = PendingItem(snippet: '心脾');
      final r = PendingFixer.apply(text, item, '离生心皮');
      expect(r.text, '甲离生心皮乙');
    });

    test('替换成更短的词也不乱', () {
      const text = '甲离生心皮乙';
      const item = PendingItem(snippet: '离生心皮');
      final r = PendingFixer.apply(text, item, '心皮');
      expect(r.text, '甲心皮乙');
    });
  });

  group('找不到时的行为', () {
    test('片段不在正文里，replaced=0 且原文不变', () {
      const text = '这段没有那个词。';
      const item = PendingItem(snippet: '木兰科');
      final r = PendingFixer.apply(text, item, '木兰科属');
      expect(r.replaced, 0);
      expect(r.text, text);
      expect(r.changed, isFalse, reason: '没替上就不能说 changed');
    });

    test('空片段不执行替换（防死循环）', () {
      const text = '有内容的文本';
      const item = PendingItem(snippet: '');
      final r = PendingFixer.apply(text, item, '替换');
      expect(r.replaced, 0);
      expect(r.text, text);
    });

    test('空替换词不执行', () {
      const text = '心脾很重要';
      const item = PendingItem(snippet: '心脾');
      final r = PendingFixer.apply(text, item, '');
      expect(r.replaced, 0);
      expect(r.text, text);
    });

    test('空原文不崩', () {
      const item = PendingItem(snippet: '心脾');
      final r = PendingFixer.apply('', item, '心皮');
      expect(r.replaced, 0);
    });
  });

  group('替换后的待确认项处理', () {
    test('被替换的那条从列表里移除', () {
      const text = '心脾很重要，雄瑞群也要注意。';
      const item = PendingItem(snippet: '心脾');
      final r = PendingFixer.apply(text, item, '心皮');
      expect(r.remainingPending, isEmpty,
          reason: '已人工确认的项不该还挂着');
    });

    test('替换失败时该条保留（还能再试）', () {
      const text = '原文里没有这个词';
      const item = PendingItem(snippet: '心脾');
      final r = PendingFixer.apply(text, item, '心皮');
      expect(r.remainingPending.length, 1);
      expect(r.remainingPending.first.snippet, '心脾');
    });

    test('relocateAll 在新文本上重算位置', () {
      const oldText = '心脾在前面，雄瑞群在后面。';
      // 假设把「心脾」换成了更长的词，后面的位置整体后移
      const newText = '离生心皮在前面，雄瑞群在后面。';
      const items = [
        PendingItem(snippet: '心脾'),
        PendingItem(snippet: '雄瑞群'),
      ];
      final relocated = PendingFixer.relocateAll(newText, items);
      // 雄瑞群在新文本里的位置
      expect(relocated[1].firstPosition, newText.indexOf('雄瑞群'));
      expect(relocated[1].canLocate, isTrue);
      // 心脾已经被替换掉，新文本里找不到
      expect(relocated[0].canLocate, isFalse);
      // 对比：如果不重算，用老位置就会指错
      expect(oldText.indexOf('雄瑞群'), isNot(newText.indexOf('雄瑞群')));
    });

    test('relocateAll 对空列表返回空', () {
      expect(PendingFixer.relocateAll('文本', const []), isEmpty);
    });

    test('relocateAll 保留候选与次数', () {
      const items = [
        PendingItem(
          snippet: '心脾',
          candidates: ['心皮'],
          count: 3,
          positions: [0],
        ),
      ];
      final relocated = PendingFixer.relocateAll('后面才有心脾', items);
      expect(relocated.single.candidates, ['心皮']);
      expect(relocated.single.count, 3);
      expect(relocated.single.firstPosition, 4);
    });
  });

  group('替换后位置正确性（最容易错的地方）', () {
    test('替换后剩余项的位置指向的是新词，不是旧位置', () {
      // 「心脾」在 0，「雄瑞群」在 6。
      // 把心脾换成三字词后，雄瑞群应后移到 8。
      const text = '心脾，雄瑞群在后面';
      const target = PendingItem(snippet: '心脾');
      final r = PendingFixer.apply(text, target, '离生心皮');
      expect(r.text, '离生心皮，雄瑞群在后面');

      const others = [PendingItem(snippet: '雄瑞群')];
      final relocated = PendingFixer.relocateAll(r.text, others);
      final pos = relocated.single.firstPosition!;
      expect(pos, r.text.indexOf('雄瑞群'));
      // 用新位置取片段，必须真是那个词
      expect(r.text.substring(pos, pos + '雄瑞群'.length), '雄瑞群');
    });
  });
}