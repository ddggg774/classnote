// lib/services/settings_service.dart
// 设置服务：用 shared_preferences 在本地保存/读取用户配置。
// 保存 DeepSeek Key（总结）和硅基流动 Key（语音识别），做到"改 Key 不用重新打包"。
//
// 【迁移历史】
// 旧版把硅基流动的 Key 存在键名 "aliyun_asr_key" 下（早期试过阿里云的遗留命名）。
// 换成 siliconflow_asr_key 时必须保留读取旧键的兼容逻辑，否则老用户升级后 Key 直接失效。
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

class SettingsService {
  // 单例
  SettingsService._internal();
  static final SettingsService _instance = SettingsService._internal();
  factory SettingsService() => _instance;

  static const String _keyApiKey = 'deepseek_api_key';
  static const String _keyAsrKey = 'siliconflow_asr_key';

  /// 语音识别模型（可在设置页切换）
  static const String _keyAsrModel = 'asr_model';
  /// 术语表：用户填写的专业名词，用于本地纠错
  static const String _keyGlossary = 'glossary_terms';
  /// 转写完成后是否自动 AI 纠错
  static const String _keyAutoCorrect = 'auto_correct_enabled';
  static const String _keyCaptureProfile = 'capture_profile';
  /// 质检时是否联网检索中文维基（隐私条款 v1.1 已披露；默认开启，可在设置关闭）
  static const String _keyWikiSearch = 'wiki_search_enabled';

  /// 免责声明：已同意的版本号与同意时间（本机记录，不上传）
  static const String _keyDisclaimerVersion = 'disclaimer_version';
  static const String _keyDisclaimerAt = 'disclaimer_accepted_at';

  /// 进程内缓存，供只读页显示「已同意版本/时间」
  static String? lastAcceptedVersion;
  static int? lastAcceptedAt;

  /// 版本号不同的条款需要重新同意；从未同意过也需要。
  /// 抽成纯函数是为了能在测试里验证，不用碰 SharedPreferences。
  static bool needsDisclaimerAcceptance(
    String? storedVersion,
    String currentVersion,
  ) =>
      storedVersion == null || storedVersion != currentVersion;

  /// 读取是否已同意当前版本（同时刷新进程内缓存）
  Future<bool> hasAcceptedDisclaimer(String currentVersion) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_keyDisclaimerVersion);
    lastAcceptedVersion = stored;
    lastAcceptedAt = prefs.getInt(_keyDisclaimerAt);
    return !needsDisclaimerAcceptance(stored, currentVersion);
  }

  /// 记录同意：版本号 + 时间戳
  Future<void> acceptDisclaimer(String version) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;
    await prefs.setString(_keyDisclaimerVersion, version);
    await prefs.setInt(_keyDisclaimerAt, now);
    lastAcceptedVersion = version;
    lastAcceptedAt = now;
  }

  /// 旧键名，仅用于一次性迁移读取
  static const String _legacyAsrKey = 'aliyun_asr_key';

  /// 保存 API Key
  Future<void> saveApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyApiKey, key.trim());
  }

  /// 读取 API Key；未设置时返回空字符串
  Future<String> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyApiKey) ?? '';
  }

  /// 是否已配置 Key
  Future<bool> hasApiKey() async {
    return (await getApiKey()).isNotEmpty;
  }

  // ─── 硅基流动语音识别 Key ───

  /// 保存硅基流动 API Key。传空字符串表示「清除」。
  Future<void> saveAsrKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final value = key.trim();
    if (value.isEmpty) {
      await prefs.remove(_keyAsrKey);
      await prefs.remove(_legacyAsrKey);
      return;
    }
    await prefs.setString(_keyAsrKey, value);
  }

  /// 读取硅基流动 API Key；未设置时返回空字符串。
  /// 会自动把旧键名 aliyun_asr_key 的值迁移到新键名（只做一次）。
  Future<String> getAsrKey() async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getString(_keyAsrKey);
    if (current != null && current.isNotEmpty) return current;

    final legacy = prefs.getString(_legacyAsrKey);
    if (legacy != null && legacy.isNotEmpty) {
      // 迁移：写入新键、保留旧键一个版本以便回滚
      await prefs.setString(_keyAsrKey, legacy);
      return legacy;
    }
    return '';
  }

  Future<bool> hasAsrKey() async => (await getAsrKey()).isNotEmpty;

  // ─── 语音识别模型 ───

  /// 读取当前选用的识别模型；未设置时用默认值。
  Future<String> getAsrModel() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_keyAsrModel);
    if (saved != null && saved.isNotEmpty) return saved;
    return AppConfig.asrModel;
  }

  Future<void> saveAsrModel(String model) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAsrModel, model);
  }

  // ─── 术语表与纠错 ───

  /// 读取术语表（每行一个，或逗号分隔，已在写入时规整成换行分隔）。
  Future<String> getGlossary() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyGlossary) ?? '';
  }

  /// 保存术语表。会把逗号/顿号/分号统一成换行，方便下游按行切分。
  Future<void> saveGlossary(String raw) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = raw
        .split(RegExp(r'[\n,，、;；]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .join('\n');
    if (normalized.isEmpty) {
      await prefs.remove(_keyGlossary);
    } else {
      await prefs.setString(_keyGlossary, normalized);
    }
  }

  /// 是否在转写完成后自动做 AI 纠错（默认关闭：会多花一次调用并让收尾变慢）
  Future<bool> getAutoCorrect() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyAutoCorrect) ?? false;
  }

  Future<void> saveAutoCorrect(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAutoCorrect, enabled);
  }

  /// 拾音档位（安静教室 / 普通教室 / 大教室后排）
  Future<String> getCaptureProfile() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyCaptureProfile) ?? 'normal';
  }

  Future<void> saveCaptureProfile(String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCaptureProfile, code);
  }

  /// 质检是否联网检索维基百科（默认开启）
  Future<bool> getWikiSearchEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyWikiSearch) ?? true;
  }

  Future<void> saveWikiSearchEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyWikiSearch, enabled);
  }
}
