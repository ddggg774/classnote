// lib/models/summary_level.dart
// 总结详细度三档。
//
// 【三档的定位】
//   brief  速览：只留知识点层级 + 考试/作业提示，目标是"一屏看完、考前一分钟扫一眼"
//   normal 标准：现有九段式，完整但不啰嗦
//   detail 详细：九段式 + 每段带原文引用与时间戳，用于逐字复盘
//
// 【为什么不做成"字数比例"】
// 按字数控制会逼模型注水（凑够字数）或删干货（压到上限）。
// 按"保留哪些章节 + 是否带原文引证"来控制，结构清晰、可验证，也不会为了凑长度编内容。
import 'dart:convert';

enum SummaryLevel {
  brief('brief', '速览', '只留知识点层级与考试作业提示，一屏看完'),
  normal('normal', '标准', '完整九段式，信息全但不啰嗦'),
  detail('detail', '详细', '九段式 + 原文引用与时间戳，可逐字复盘');

  const SummaryLevel(this.code, this.label, this.description);

  final String code;
  final String label;
  final String description;

  static SummaryLevel fromCode(String? code) {
    switch (code) {
      case 'brief':
        return SummaryLevel.brief;
      case 'detail':
        return SummaryLevel.detail;
      case 'normal':
      default:
        return SummaryLevel.normal;
    }
  }

  /// 是否保留原文引用与时间戳
  bool get needsCitations => this == SummaryLevel.detail;
}

/// 解析模型返回的 JSON 时，容忍模型给的中文/大写等写法
SummaryLevel parseLevel(String? raw) {
  final s = (raw ?? '').trim().toLowerCase();
  if (s.isEmpty) return SummaryLevel.normal;
  if (s.contains('brief') || s.contains('速览') || s.contains('简')) {
    return SummaryLevel.brief;
  }
  if (s.contains('detail') || s.contains('详细') || s.contains('完整')) {
    return SummaryLevel.detail;
  }
  return SummaryLevel.normal;
}

/// 仅测试用
String debugLevelJson(SummaryLevel level) =>
    jsonEncode({'level': level.code});
