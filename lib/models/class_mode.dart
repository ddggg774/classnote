// lib/models/class_mode.dart
// 记录页的两种形态：普通（中文）课堂 与 英语课。
//
// 【为什么用「入口 + mode」而不是给中文页加语言开关】
// 英语课要的是另一套体验（固定 en、始终带翻译），不是中文页上一个能选错的下拉框。
// 入口决定语言，用户不需要理解语言字段。
//
// 【为什么不是复制一个 RecordPage】
// 那个页面有 1100 行状态机（录音、切片、草稿自动保存、前台服务、位置选择），
// 复制一份等于以后每个 bug 都要修两遍，而且两份迟早会跑偏。
enum ClassMode {
  /// 普通课堂（中文链路，行为与 v1.1.0 完全一致）
  chinese,

  /// 英语课：固定 en，转写后逐句翻译
  english;

  String get languageCode => this == ClassMode.english ? 'en' : 'zh';

  String get appBarTitle =>
      this == ClassMode.english ? '英语课' : '新建课堂记录';

  /// 是否启用翻译（只有英语课）
  bool get translates => this == ClassMode.english;
}