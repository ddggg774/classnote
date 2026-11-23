// lib/services/desensitizer.dart
// 发送到外部 App 前的脱敏：手机号、身份证、邮箱、学号/工号、QQ/微信。
//
// 只做「确定会泄露身份」的格式替换，不做 NER 人名识别——
// 人名识别会误伤专业术语（如「木兰科」），宁可漏也不乱改。
class Desensitizer {
  const Desensitizer._();

  // 容忍 138-0013-8000 / 138 0013 8000 / +86 138… 这几种手写格式
  static final RegExp _phone = RegExp(
      r'(?<!\d)(?:\+?86[- ]?)?1[3-9]\d[- ]?\d{4}[- ]?\d{4}(?!\d)');
  static final RegExp _idCard = RegExp(r'(?<!\d)\d{17}[\dXx](?!\d)');
  static final RegExp _email = RegExp(r'[\w.+-]+@[\w-]+\.[\w.]+');
  static final RegExp _studentNo =
      RegExp(r'(学号|工号|编号)\s*[:：]?\s*\d{6,}');
  static final RegExp _im =
      RegExp(r'(QQ|qq|微信|电话|手机)\s*[:：]?\s*[0-9A-Za-z_-]{5,}');

  static String apply(String text) {
    var out = text;
    out = out.replaceAll(_idCard, '【身份证】');
    out = out.replaceAll(_phone, '【手机号】');
    out = out.replaceAll(_email, '【邮箱】');
    out = out.replaceAllMapped(_studentNo, (m) => '${m.group(1)}【已隐藏】');
    out = out.replaceAllMapped(_im, (m) => '${m.group(1)}【已隐藏】');
    return out;
  }

  /// 是否发生了替换（界面可提示"已脱敏 N 处"用不到精确数，布尔足够）
  static bool changed(String before, String after) => before != after;
}
