// test/translation_service_test.dart
// 翻译服务的校验逻辑测试（不联网）。
//
// 这里不测"模型翻得好不好"——那是模型的事，测了也不稳。
// 测的是：模型乱回时，程序有没有拦住。
//   · 句数对不上 → 重试 → 整段降级
//   · src 被改写 → 拦下
//   · 代码围栏 → 能剥掉
// 这些是"逐句对照"不崩的底线。

import 'package:flutter_test/flutter_test.dart';

import 'package:classnote/services/ai_service.dart';
import 'package:classnote/services/translation_service.dart';

/// 假模型：按顺序吐预设回复，调用次数可查。
class _FakeAi extends AiService {
  _FakeAi(this.responses) : super(apiKeyOverride: 'test-key');

  final List<String> responses;
  int calls = 0;

  @override
  Future<String> complete({
    required String system,
    required String user,
    double temperature = 0.3,
    int maxTokens = 2500,
  }) async {
    final index = calls < responses.length ? calls : responses.length - 1;
    calls++;
    return responses[index];
  }
}

void main() {
  const text = 'Plants have cell walls. Leaves capture light.';
  const goodJson = '{"pairs":['
      '{"i":1,"src":"Plants have cell walls.","dst":"植物有细胞壁。"},'
      '{"i":2,"src":"Leaves capture light.","dst":"叶片捕捉光。"}]}';

  test('正常逐句翻译：条数、编号、原文都能对上', () async {
    final service = TranslationService(ai: _FakeAi([goodJson]));
    final result =
        await service.translate(text: text, sourceLang: 'en');
    expect(result.mode, 'per-sentence');
    expect(result.isPerSentence, isTrue);
    expect(result.pairs.length, 2);
    expect(result.pairs[0].index, 1);
    expect(result.pairs[0].target, '植物有细胞壁。');
    expect(result.pairs[1].source, 'Leaves capture light.');
  });

  test('带代码围栏的 JSON 也能解析', () async {
    final service = TranslationService(ai: _FakeAi(['```json\n$goodJson\n```']));
    final result =
        await service.translate(text: text, sourceLang: 'en');
    expect(result.mode, 'per-sentence');
    expect(result.pairs.length, 2);
  });

  test('句数对不上：先重试，两次都不行就整段降级', () async {
    final fake = _FakeAi([
      '{"pairs":[{"i":1,"src":"Plants have cell walls.","dst":"植物有细胞壁。"}]}',
      '{"pairs":[]}',
      '植物有细胞壁。叶片捕捉光。',
    ]);
    final service = TranslationService(ai: fake);
    final result =
        await service.translate(text: text, sourceLang: 'en');
    expect(result.mode, 'whole');
    expect(result.isPerSentence, isFalse);
    expect(result.pairs.single.target, contains('植物'));
    expect(fake.calls, 3); // 两次逐句 + 一次整段
  });

  test('模型擅自改写 src：拦下并降级', () async {
    final fake = _FakeAi([
      '{"pairs":['
          '{"i":1,"src":"Plants possess cell walls.","dst":"植物有细胞壁。"},'
          '{"i":2,"src":"Leaves capture light.","dst":"叶片捕捉光。"}]}',
      '{"pairs":[]}',
      '植物有细胞壁。叶片捕捉光。',
    ]);
    final service = TranslationService(ai: fake);
    final result =
        await service.translate(text: text, sourceLang: 'en');
    expect(result.mode, 'whole');
  });

  test('无译文条目的空 dst 也被拦下', () async {
    final fake = _FakeAi([
      '{"pairs":['
          '{"i":1,"src":"Plants have cell walls.","dst":""},'
          '{"i":2,"src":"Leaves capture light.","dst":"叶片捕捉光。"}]}',
      '{"pairs":[]}',
      '植物有细胞壁。叶片捕捉光。',
    ]);
    final result =
        await TranslationService(ai: fake).translate(text: text, sourceLang: 'en');
    expect(result.mode, 'whole');
  });

  test('空文本直接抛异常，不发请求', () async {
    final fake = _FakeAi([goodJson]);
    expect(
      () => TranslationService(ai: fake).translate(text: '   ', sourceLang: 'en'),
      throwsA(isA<Exception>()),
    );
    expect(fake.calls, 0);
  });

  test('TranslationResult 编解码往返', () async {
    final result = await TranslationService(ai: _FakeAi([goodJson]))
        .translate(text: text, sourceLang: 'en');
    final decoded = TranslationResult.tryDecode(result.encode());
    expect(decoded, isNotNull);
    expect(decoded!.pairs.length, 2);
    expect(decoded.pairs[1].target, '叶片捕捉光。');
    expect(decoded.sourceLang, 'en');
    expect(decoded.mode, 'per-sentence');
  });
}