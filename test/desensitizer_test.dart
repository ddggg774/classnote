// test/desensitizer_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/services/desensitizer.dart';

void main() {
  test('手机号、身份证、邮箱被替换', () {
    const raw = '老师电话 13812345678，邮箱 zhang@example.com，身份证 110101199001011234。';
    final out = Desensitizer.apply(raw);
    expect(out, isNot(contains('13812345678')));
    expect(out, isNot(contains('zhang@example.com')));
    expect(out, isNot(contains('110101199001011234')));
    expect(out, contains('【手机号】'));
    expect(out, contains('【邮箱】'));
    expect(out, contains('【身份证】'));
  });

  test('学号/工号前缀保留，数字隐藏', () {
    final out = Desensitizer.apply('学号 2023012345，工号：88889999');
    expect(out, contains('学号【已隐藏】'));
    expect(out, contains('工号【已隐藏】'));
    expect(out, isNot(contains('2023012345')));
  });

  test('专业术语与普通数字不被误伤', () {
    const raw = '木兰科有 12 属，芋头是球茎，第四章第 3 节。';
    expect(Desensitizer.apply(raw), raw);
  });

  test('QQ/微信字段被隐藏', () {
    final out = Desensitizer.apply('QQ: 123456789');
    expect(out, isNot(contains('123456789')));
    expect(out, contains('QQ【已隐藏】'));
  });

  test('带分隔符和 +86 的手机号也能脱敏', () {
    for (final raw in [
      '电话 138-0013-8000',
      '电话 138 0013 8000',
      '电话 +86 13800138000',
    ]) {
      final out = Desensitizer.apply(raw);
      expect(out, contains('【手机号】'), reason: raw);
      expect(out, isNot(contains('0013')), reason: raw);
    }
  });
}
