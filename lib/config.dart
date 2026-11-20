// lib/config.dart
// 全局配置：集中放可配置项，避免散落在代码各处。
class AppConfig {
  // ─────────────────────────────────────────────────────────
  // DeepSeek API 配置
  // 注意：API Key 不再硬编码在这里，而是用户在 App 内「设置」页动态填写，
  // 保存在本地（见 services/settings_service.dart），修改后无需重新打包。
  // 申请地址：https://platform.deepseek.com
  // ─────────────────────────────────────────────────────────
  static const String deepSeekBaseUrl = 'https://api.deepseek.com/v1/chat/completions';
  static const String deepSeekModel = 'deepseek-chat';

  // 硅基流动语音识别：whisper 式 /audio/transcriptions 接口。
  //
  // 【接口能力边界 · 2026-11 核对官方文档】
  // 请求体只有两个字段：file（音频，≤1 小时 / ≤50MB）和 model（模型名）。
  // 没有 hotwords / prompt / language / response_format —— 所以"传热词提升准确率"
  // 这条路在硅基流动上走不通，别白费力气去加参数（加了也不会生效）。
  // 提升准确率只能靠：① 换同接口下的另一个模型；② 本地做术语表 + LLM 纠错后处理。
  //
  // 同一接口下的可选模型（切换只需改模型名，Key 和调用方式完全不变）：
  //   FunAudioLLM/SenseVoiceSmall —— 默认，长期免费，中文快
  //   TeleAI/TeleSpeechASR        —— 另一个中文识别选择，可与上面互相备选
  // Key 在 App 内「设置」页填写，保存在本地。申请地址：https://cloud.siliconflow.cn
  static const String asrBaseUrl =
      'https://api.siliconflow.cn/v1/audio/transcriptions';

  /// 默认模型。用户在设置页可切换，运行时以设置为准。
  static const String asrModel = 'FunAudioLLM/SenseVoiceSmall';

  /// 可在设置页选择的识别模型（value 用于 API，label 用于界面）
  static const List<({String value, String label, String note})>
      asrModelOptions = [
    (
      value: 'FunAudioLLM/SenseVoiceSmall',
      label: 'SenseVoiceSmall（默认）',
      note: '免费、速度快，中文课堂通用',
    ),
    (
      value: 'TeleAI/TeleSpeechASR',
      label: 'TeleSpeechASR',
      note: '另一个中文识别模型，觉得不准时换它对比',
    ),
  ];

  // 语音识别语言：简体中文。如需英文改为 'en'
  // 注意：当前硅基流动接口并不接收 language 参数，这里仅保留给将来可能切换的厂商用。
  static const String speechLocale = 'zh_CN';

  // ─────────────────────────────────────────────────────────
  // 教材信息：用来自动识别课程，并把教材名带进术语生成/纠错提示词。
  // 用户实际在用的三本（2026-11 确认）：
  //   植物学（第三版）方炎明 主编，中国林业出版社
  //   建筑制图（第四版），东南大学出版社
  //   园林制图
  // ─────────────────────────────────────────────────────────
  static const List<({String course, String book, String publisher, String author})>
      textbooks = [
    (
      course: '植物学',
      book: '植物学（第三版）',
      author: '方炎明 主编',
      publisher: '中国林业出版社',
    ),
    (
      course: '建筑制图',
      book: '建筑制图（第四版）',
      author: '',
      publisher: '东南大学出版社',
    ),
    (
      course: '园林制图',
      book: '园林制图',
      author: '',
      publisher: '',
    ),
  ];

  /// 按课程名匹配教材（模糊匹配，因为用户可能只写"植物学"或"植物"）
  static ({String course, String book, String publisher, String author})?
      textbookOf(String courseName) {
    final q = courseName.trim();
    if (q.isEmpty) return null;
    for (final t in textbooks) {
      if (q.contains(t.course) || t.course.contains(q)) return t;
    }
    return null;
  }

  /// 拼成一句可读的教材描述，给提示词用；匹配不到返回空串
  static String textbookLine(String courseName) {
    final t = textbookOf(courseName);
    if (t == null) return '';
    final parts = <String>[t.book];
    if (t.author.isNotEmpty) parts.add(t.author);
    if (t.publisher.isNotEmpty) parts.add(t.publisher);
    return parts.join('，');
  }

  // 数据库文件名
  static const String dbName = 'classnote.db';
}
