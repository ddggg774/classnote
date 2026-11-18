// lib/services/asr_service.dart
// 语音转写服务：封装 speech_to_text 插件，实现"边说边出字"。
// 这是"网络/设备能力层"，页面只管调用 start/stop 并拿文字。
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';

import '../config.dart';

class AsrService {
  final SpeechToText _speech = SpeechToText();
  bool _initialized = false;

  // 设备是否支持语音识别（不支持时页面要提示用户改用手动输入）
  bool get available => _speech.isAvailable;

  /// 初始化：申请麦克风权限并加载语音识别引擎。
  /// 返回 true 表示可用；失败原因通过 [onError] 回调给出可操作的提示。
  Future<bool> initialize({required Function(String msg) onError}) async {
    if (_initialized) return true;
    try {
      // 先查权限状态，便于区分"没授权"和"设备没有语音引擎"
      final hasPerm = await _speech.hasPermission;

      final ok = await _speech.initialize(
        // 打开插件详细日志，真机排查时能看清底层原因
        debugLogging: true,
        onError: (error) {
          onError('语音识别出错：${error.errorMsg}（${error.permanent ? "永久" : "临时"}）');
        },
        onStatus: (status) {
          // done / listening / notListening 等状态，这里仅留出扩展位
        },
      );
      _initialized = ok;
      if (!ok) {
        // 初始化失败：给出分场景的可操作提示
        if (!hasPerm) {
          onError('未获得麦克风权限。请到「手机设置 → 应用 → 课堂笔记 → 权限」中开启麦克风，然后重新打开 App');
        } else {
          onError('本机未找到可用的语音识别服务（部分国产手机无 Google 语音服务）。'
              '可先手动输入文字记录，或用带语音引擎的机型测试');
        }
      }
      return ok;
    } catch (e) {
      onError('语音识别初始化失败：$e');
      return false;
    }
  }

  /// 开始实时识别。
  /// [onText] 每次识别出文字都会回调，参数是从开始到当前的完整文字。
  Future<void> start({
    required Function(String text) onText,
    required Function(String msg) onError,
  }) async {
    // 未初始化时先初始化
    if (!_initialized) {
      final ok = await initialize(onError: onError);
      if (!ok) return;
    }
    await _speech.listen(
      onResult: (SpeechRecognitionResult result) {
        // recognizedWords 是本次识别会话累积的文字，直接作为实时转写内容
        onText(result.recognizedWords);
      },
      listenOptions: SpeechListenOptions(
        localeId: AppConfig.speechLocale,
        listenFor: const Duration(minutes: 60),   // 单节课最长 60 分钟
        pauseFor: const Duration(seconds: 4),      // 停顿 4 秒后自动断句
        cancelOnError: false,
        partialResults: true,                      // 允许返回"进行中"的文字
      ),
    );
  }

  /// 停止识别
  Future<void> stop() async {
    await _speech.stop();
  }

  /// 是否正在监听
  bool get isListening => _speech.isListening;
}
