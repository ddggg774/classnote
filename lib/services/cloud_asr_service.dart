// lib/services/cloud_asr_service.dart
// 云端语音识别服务（自动分段版）：
// 录音 → 每隔约 5 分钟自动切一段 → 上传硅基流动 SenseVoiceSmall → 文字按序追加。
// 用户只需「开始」一次、录到结束点「停止」，中间不用管，无总时长限制。
// 不依赖手机系统语音引擎，任何手机（含无 Google 服务的国产机）都能用。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../config.dart';
import 'settings_service.dart';

class CloudAsrService {
  final AudioRecorder _recorder = AudioRecorder();
  final SettingsService _settings = SettingsService();

  Timer? _chunkTimer;
  String? _currentPath;
  int _chunkIndex = 0;          // 当前正在录的段号
  int _nextToAppend = 0;        // 下一个该回调给页面的段号（保证顺序）
  bool _recording = false;
  bool _processing = false;

  final Map<int, String> _pendingPaths = {}; // 待识别段的 段号→文件路径
  final List<int> _queue = [];               // 待识别段号队列
  final Map<int, String> _results = {};      // 已完成识别结果

  Function(String text)? _onText;            // 每完成一段，回调该段文字
  Function(String msg)? _onError;

  // 每段时长：5 分钟。16kHz 单声道 wav 约 9MB，远低于硅基流动 50MB 上限。
  // 分段大一些可减少请求次数、更省时间；识别失败时损失也仅一段。
  static const int chunkSeconds = 300;

  bool get isRecording => _recording;

  Future<bool> hasPermission() => _recorder.hasPermission();

  /// 开始录音。onText 每识别完一段就回调该段文字（按录制顺序）；onError 报告错误。
  Future<void> startRecording({
    required Function(String text) onText,
    required Function(String msg) onError,
  }) async {
    _onText = onText;
    _onError = onError;
    _chunkIndex = 0;
    _nextToAppend = 0;
    _results.clear();
    _queue.clear();
    _pendingPaths.clear();

    final key = await _settings.getAsrKey();
    if (key.isEmpty) {
      onError('请先在「设置」里填写硅基流动 API Key');
      return;
    }

    _recording = true;
    await _startNewChunk();
    _chunkTimer = Timer.periodic(const Duration(seconds: chunkSeconds), (_) {
      _rotateChunk();
    });
  }

  Future<void> _startNewChunk() async {
    final dir = await getTemporaryDirectory();
    _currentPath = '${dir.path}/classnote_${DateTime.now().microsecondsSinceEpoch}_$_chunkIndex.wav';
    const config = RecordConfig(
      encoder: AudioEncoder.wav,
      sampleRate: 16000,
      numChannels: 1,
    );
    await _recorder.start(config, path: _currentPath!);
  }

  /// 切段：停止当前段 → 排进识别队列 → 立刻开始下一段（录音不中断流程）
  Future<void> _rotateChunk() async {
    if (!_recording) return;
    final path = _currentPath;
    final idx = _chunkIndex;
    try {
      await _recorder.stop();
    } catch (_) {}
    _chunkIndex++;
    if (path != null) {
      _pendingPaths[idx] = path;
      _queue.add(idx);
      _processQueue(); // 后台识别，不阻塞录音
    }
    if (_recording) await _startNewChunk();
  }

  /// 顺序处理识别队列：保证文字按录制顺序回调
  Future<void> _processQueue() async {
    if (_processing) return;
    _processing = true;
    while (_queue.isNotEmpty) {
      final idx = _queue.removeAt(0);
      final path = _pendingPaths[idx];
      if (path == null) continue;
      String text = '';
      try {
        text = await recognize(path);
      } catch (e) {
        _onError?.call(e.toString().replaceFirst('Exception: ', ''));
      }
      _results[idx] = text;
      // 按序把连续完成的段回调出去
      while (_results.containsKey(_nextToAppend)) {
        final t = _results.remove(_nextToAppend)!;
        if (t.isNotEmpty) _onText?.call(t);
        _nextToAppend++;
      }
    }
    _processing = false;
  }

  /// 停止录音：停掉计时器和当前段，等所有段识别完再返回
  Future<void> stopRecording() async {
    _chunkTimer?.cancel();
    _chunkTimer = null;
    if (!_recording) return;
    _recording = false;

    final path = _currentPath;
    final idx = _chunkIndex;
    if (path != null) {
      try {
        await _recorder.stop();
        _pendingPaths[idx] = path;
        _queue.add(idx);
        _processQueue();
      } catch (_) {}
    }
    // 等待队列识别完毕
    while (_processing || _queue.isNotEmpty) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }

  /// 把一段音频转成文字（供队列调用）
  /// 硅基流动 whisper 式接口：POST multipart/form-data，字段 file + model，返回 {"text": ...}。
  Future<String> recognize(String filePath) async {
    final apiKey = await _settings.getAsrKey();
    if (apiKey.isEmpty) throw Exception('请先在「设置」里填写硅基流动 API Key');

    final file = File(filePath);
    if (!await file.exists()) throw Exception('录音文件不存在');

    // multipart 上传：文件字段叫 file，模型字段叫 model
    final uri = Uri.parse(AppConfig.asrBaseUrl);
    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $apiKey'
      ..fields['model'] = AppConfig.asrModel
      ..files.add(await http.MultipartFile.fromPath('file', filePath, filename: 'audio.wav'));

    late final http.StreamedResponse streamed;
    try {
      streamed = await request.send().timeout(const Duration(seconds: 120));
    } catch (e) {
      throw Exception('网络请求失败，请检查网络后重试（$e）');
    }
    final response = await http.Response.fromStream(streamed);

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw Exception('硅基流动 API Key 无效或未实名，请到设置里检查 Key');
    }
    if (response.statusCode == 429) {
      throw Exception('请求太频繁，请稍后再试');
    }
    if (response.statusCode != 200) {
      String detail = response.body;
      try {
        final err = jsonDecode(response.body);
        detail = err['message'] ?? err['data'] ?? response.body;
      } catch (_) {}
      final s = detail.toString();
      throw Exception('识别失败（${response.statusCode}）：${s.length > 120 ? s.substring(0, 120) : s}');
    }

    final data = jsonDecode(response.body);
    final text = data['text'] as String?;
    if (text == null || text.trim().isEmpty) {
      throw Exception('有一段没识别到文字，可能环境太吵');
    }
    // 录完一段就删掉本地临时文件，省空间
    try { await file.delete(); } catch (_) {}
    return text.trim();
  }

  Future<void> dispose() async {
    _chunkTimer?.cancel();
    await _recorder.dispose();
  }
}
