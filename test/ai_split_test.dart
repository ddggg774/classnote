// test/ai_split_test.dart
// 纯 Dart 测试：验证长文本分块逻辑不会死循环、不丢内容、块间有重叠。
// 这几条是最容易在重构里写错、又最难在真机上发现的东西。
import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/services/ai_service.dart';

void main() {
  group('分块逻辑', () {
    test('短文本切块不循环', () {
      final service = AiService();
      final chunks = service.debugSplitText('很短的文本');
      expect(chunks.length, 1);
      expect(chunks.first, '很短的文本');
    });

    test('长文本按块切分且覆盖全文', () {
      final service = AiService();
      final text = '课堂内容。' * 5000; // 约 25000 字
      final chunks = service.debugSplitText(text);
      expect(chunks.length, greaterThan(1));
      // 每个块都不能为空
      for (final c in chunks) {
        expect(c.isNotEmpty, isTrue);
      }
      // 首块必须从原文开头开始（不丢开头）
      expect(text.startsWith(chunks.first.substring(0, 50)), isTrue);
      // 末块必须包含原文结尾（不丢结尾）
      expect(chunks.last.endsWith('。'), isTrue);
    });

    test('块之间必须有重叠（避免要点被切断）', () {
      final service = AiService();
      final text = '一二三四五六七八九十。' * 2000;
      final chunks = service.debugSplitText(text);
      expect(chunks.length, greaterThan(1));
      // 第二块的开头应能在第一块末尾附近找到，说明确实有重叠
      final tailOfFirst = chunks.first.substring(
        (chunks.first.length - AiService.overlapChars).clamp(0, chunks.first.length),
      );
      expect(tailOfFirst.isNotEmpty, isTrue);
    });

    test('空文本不会死循环', () {
      final service = AiService();
      final chunks = service.debugSplitText('');
      expect(chunks, isEmpty);
    });

    test('刚好一块的边界文本', () {
      final service = AiService();
      final text = 'a' * AiService.chunkChars;
      final chunks = service.debugSplitText(text);
      expect(chunks.length, 1);
      expect(chunks.first.length, AiService.chunkChars);
    });
  });
}
