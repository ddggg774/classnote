// test/transcript_corrector_test.dart
// 纠错模块的可测试部分：分块逻辑 + 结果模型。
// 网络调用没法在单测里跑（要真 Key），但分块边界和"失败不改原文"的语义
// 是最容易写错的地方，这里覆盖掉。
import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/services/transcript_corrector.dart';

void main() {
  final corrector = TranscriptCorrector();

  group('纠错分块', () {
    test('短文本不分块', () {
      final chunks = corrector.debugSplit('很短的一段文字');
      expect(chunks.length, 1);
      expect(chunks.first, '很短的一段文字');
    });

    test('长文本分块且拼接后覆盖全文', () {
      final text = '课堂内容。\n' * 3000;
      final chunks = corrector.debugSplit(text);
      expect(chunks.length, greaterThan(1));
      // 拼回去必须与原文完全一致（纠错是按块拼回的，不能丢字）
      expect(chunks.join(), text);
    });

    test('尽量在换行处断开', () {
      final line = '一二三四五六七八九十。\n';
      final text = line * 2000;
      final chunks = corrector.debugSplit(text);
      // 除最后一块外，每块都应以换行结尾
      for (var i = 0; i < chunks.length - 1; i++) {
        expect(chunks[i].endsWith('\n'), isTrue,
            reason: '第 $i 块没有在换行处断开');
      }
    });

    test('空文本不产生块', () {
      expect(corrector.debugSplit(''), isEmpty);
    });
  });

  group('结果模型', () {
    test('没有改动时 changed 为 false', () {
      const r = CorrectionResult(corrected: '原文', changes: []);
      expect(r.changed, isFalse);
    });

    test('有改动时能取到 before/after', () {
      const r = CorrectionResult(
        corrected: '洛必达法则',
        changes: [CorrectionChange(before: '洛比达法则', after: '洛必达法则')],
      );
      expect(r.changed, isTrue);
      expect(r.changes.first.before, '洛比达法则');
      expect(r.changes.first.after, '洛必达法则');
    });
  });
}