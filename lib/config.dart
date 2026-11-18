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

  // 硅基流动语音识别（SenseVoiceSmall）：whisper 式 /audio/transcriptions 接口。
  // 该模型官方长期免费、中文识别准、支持单次 1 小时 / 50MB，手机浏览器即可申请 Key。
  // Key 在 App 内「设置」页填写，保存在本地。申请地址：https://cloud.siliconflow.cn
  static const String asrBaseUrl = 'https://api.siliconflow.cn/v1/audio/transcriptions';
  static const String asrModel = 'FunAudioLLM/SenseVoiceSmall';

  // 语音识别语言：简体中文。如需英文改为 'en'
  static const String speechLocale = 'zh_CN';

  // 数据库文件名
  static const String dbName = 'classnote.db';
}
