// lib/services/settings_service.dart
// 设置服务：用 shared_preferences 在本地保存/读取用户配置。
// 保存 DeepSeek Key（总结）和硅基流动 Key（语音识别），做到"改 Key 不用重新打包"。
//
// 【迁移历史】
// 旧版把硅基流动的 Key 存在键名 "aliyun_asr_key" 下（早期试过阿里云的遗留命名）。
// 换成 siliconflow_asr_key 时必须保留读取旧键的兼容逻辑，否则老用户升级后 Key 直接失效。
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  // 单例
  SettingsService._internal();
  static final SettingsService _instance = SettingsService._internal();
  factory SettingsService() => _instance;

  static const String _keyApiKey = 'deepseek_api_key';
  static const String _keyAsrKey = 'siliconflow_asr_key';

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
}
