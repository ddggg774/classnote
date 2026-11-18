// lib/services/settings_service.dart
// 设置服务：用 shared_preferences 在本地保存/读取用户配置。
// 保存 DeepSeek Key（总结）和硅基流动 Key（语音识别），做到"改 Key 不用重新打包"。
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  // 单例
  SettingsService._internal();
  static final SettingsService _instance = SettingsService._internal();
  factory SettingsService() => _instance;

  static const String _keyApiKey = 'deepseek_api_key';
  static const String _keyAsrKey = 'aliyun_asr_key';

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

  /// 保存硅基流动 API Key
  Future<void> saveAsrKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAsrKey, key.trim());
  }

  /// 读取硅基流动 API Key；未设置时返回空字符串
  Future<String> getAsrKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyAsrKey) ?? '';
  }

  Future<bool> hasAsrKey() async => (await getAsrKey()).isNotEmpty;
}
