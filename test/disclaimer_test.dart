// test/disclaimer_test.dart
// 免责声明的两个关键点：
//   ① 什么情况下必须重新同意（纯函数，不碰 SharedPreferences）
//   ② 正文必须真的写了「录音合规 / AI 可能出错 / 第三方服务 / 不担保」这几件事
//
// 第 ② 条看起来像废话，但它防的是「有人把关键段落删短了还不改版本号」——
// 这种改动用户不会再看到同意页，等于悄悄改了条款。

import 'package:flutter_test/flutter_test.dart';

import 'package:classnote/pages/disclaimer_page.dart';
import 'package:classnote/services/settings_service.dart';

void main() {
  group('同意状态判定', () {
    test('从未同意过 → 必须同意', () {
      expect(
        SettingsService.needsDisclaimerAcceptance(null, '1.0'),
        isTrue,
      );
    });

    test('同意过当前版本 → 不再打扰', () {
      expect(
        SettingsService.needsDisclaimerAcceptance('1.0', '1.0'),
        isFalse,
      );
    });

    test('版本升级 → 需要重新同意', () {
      expect(
        SettingsService.needsDisclaimerAcceptance('0.9', '1.0'),
        isTrue,
      );
    });

    test('空字符串视为未同意', () {
      expect(
        SettingsService.needsDisclaimerAcceptance('', '1.0'),
        isTrue,
      );
    });
  });

  group('正文覆盖关键条款', () {
    test('录音合规与征得同意', () {
      expect(Disclaimer.text, contains('录音'));
      expect(Disclaimer.text, contains('同意'));
      expect(Disclaimer.text, contains('学校'));
    });

    test('AI 内容可能出错、不能当事实依据', () {
      expect(Disclaimer.text, contains('AI'));
      expect(Disclaimer.text, contains('核对'));
      expect(Disclaimer.text, contains('幻觉'));
    });

    test('第三方服务与费用', () {
      expect(Disclaimer.text, contains('硅基流动'));
      expect(Disclaimer.text, contains('DeepSeek'));
      expect(Disclaimer.text, contains('费用'));
    });

    test('数据存储与丢失风险', () {
      expect(Disclaimer.text, contains('本地'));
      expect(Disclaimer.text, contains('丢失'));
    });

    test('开源许可与担保排除', () {
      expect(Disclaimer.text, contains('MIT'));
      expect(Disclaimer.text, contains('担保'));
      expect(Disclaimer.text, contains('维基百科'));
      expect(Disclaimer.text, contains('责任'));
    });

    test('版本号非空，且与文档同版本', () {
      expect(Disclaimer.version, isNotEmpty);
      // 改了正文就必须改版本号，否则老用户看不到新条款
      expect(Disclaimer.version, '1.1');
    });
  });
}