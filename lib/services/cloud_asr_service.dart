// lib/services/cloud_asr_service.dart
// 云端语音识别服务（自动分段版）：
// 录音 → 按固定时长自动切段 → 上传硅基流动 SenseVoiceSmall → 文字按录制顺序回调。
// 用户只需「开始」一次、录到结束点「停止」，中间不用管，无总时长限制。
// 不依赖手机系统语音引擎，任何手机（含无 Google 服务的国产机）都能用。
//
// 【状态机说明 · 改这个文件前务必读完】
//   _recording   正在录音。只有 _startNewChunk() 成功后才置 true，失败必须回滚为 false。
//   _chunkIndex  正在录的这一段的段号（从 0 开始）。
//   _queued      已经入过队的段号集合，用来保证「同一段只会上传一次」。
//                _rotateChunk 与 stopRecording 存在时间窗口，没有它会把同一段传两遍。
//   _queue       待识别的段号（FIFO）。
//   _results     已完成段的文字，按段号暂存，直到前面的段也完成才按序吐给页面。
//   _nextToAppend 下一个该吐给页面的段号。任何一段永久失败都会在此留下占位文字并前进，
//                否则一段卡住会让后面所有文字永远出不来。
//   _failed      永久失败但仍保留音频文件的段（idx → path），供用户手动补传。
//   _idleCompleter 队列清空时 complete，替代原来的 200ms 忙轮询。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../config.dart';
import 'foreground_service.dart';
import 'audio_capture_profile.dart';
import 'settings_service.dart';

/// 识别异常：区分「重试有用」和「重试没用」。
/// 401/403（Key 错）、4xx（参数错）重试没有意义；网络/超时/5xx/429 值得退避重试。
class AsrException implements Exception {
  final String message;
  final bool retryable;
  final int? statusCode;

  AsrException(this.message, {this.retryable = true, this.statusCode});

  @override
  String toString() => message;
}

/// 单个分段的处理状态，供 UI 画小圆点
enum SegmentState { queued, uploading, done, failed }

/// 录音与识别的实时进度快照（不可变），页面订阅它来刷新 UI。
@immutable
class AsrProgress {
  final int recordedSeconds; // 已录总时长（秒）
  final int segmentNo; // 当前第几段（1 起）
  final int segmentElapsed; // 当前段已录秒数
  final int doneSegments; // 已成功识别段数
  final int pendingSegments; // 排队 + 上传中段数
  final int failedSegments; // 永久失败段数
  final String? notice; // 「第 2 段重试中 (1/3)」这类临时提示

  const AsrProgress({
    this.recordedSeconds = 0,
    this.segmentNo = 1,
    this.segmentElapsed = 0,
    this.doneSegments = 0,
    this.pendingSegments = 0,
    this.failedSegments = 0,
    this.notice,
  });

  bool get busy => pendingSegments > 0;

  AsrProgress copyWith({
    int? recordedSeconds,
    int? segmentNo,
    int? segmentElapsed,
    int? doneSegments,
    int? pendingSegments,
    int? failedSegments,
    String? notice,
    bool clearNotice = false,
  }) {
    return AsrProgress(
      recordedSeconds: recordedSeconds ?? this.recordedSeconds,
      segmentNo: segmentNo ?? this.segmentNo,
      segmentElapsed: segmentElapsed ?? this.segmentElapsed,
      doneSegments: doneSegments ?? this.doneSegments,
      pendingSegments: pendingSegments ?? this.pendingSegments,
      failedSegments: failedSegments ?? this.failedSegments,
      notice: clearNotice ? null : (notice ?? this.notice),
    );
  }

  /// 格式化成 12:34
  static String formatSeconds(int s) {
    final m = s ~/ 60;
    final sec = s % 60;
    return '$m:${sec.toString().padLeft(2, '0')}';
  }
}

class CloudAsrService {
  final AudioRecorder _recorder = AudioRecorder();

  /// 当前拾音档位（降噪/增益/回声消除）。
  /// 在录音开始时读一次并缓存，录音中途改设置不影响本次录音——
  /// 中途切换 AudioEffect 会让这一段的音质出现断层。
  CaptureProfile _profile = CaptureProfile.normal;

  /// 供界面显示"现在开了哪些音频处理"
  CaptureProfile get captureProfile => _profile;
  final SettingsService _settings = SettingsService();
  final ForegroundRecordingService _foreground = ForegroundRecordingService();

  /// 每段时长（秒）。60 秒而不是 300 秒，原因有三：
  /// ① 首段出字从 5 分钟缩短到 1 分钟，用户不会以为 App 卡死；
  /// ② 单段失败的最大损失从 5 分钟降到 1 分钟；
  /// ③ 单段 wav 从约 9.6MB 降到约 1.9MB，弱网下不至于频繁超时。
  /// 代价是每小时请求数从 12 次升到 60 次（识别按模型免费额度计，需真机确认未触发频控）。
  static const int chunkSeconds = 60;

  /// 可重试的退避间隔
  static const List<Duration> _retryDelays = [
    Duration(milliseconds: 500),
    Duration(milliseconds: 1500),
    Duration(milliseconds: 4000),
  ];

  Timer? _chunkTimer;
  String? _currentPath;
  int _chunkIndex = 0;
  int _nextToAppend = 0;
  bool _recording = false;
  bool _processing = false;
  bool _retrying = false;
  bool _disposed = false;
  StreamSubscription<RecordState>? _stateSub;

  int _recordedSeconds = 0; // 累计录音秒数（不含等待转写时间，用于修正时长统计）
  int _segmentElapsed = 0; // 当前段已录秒数

  final Map<int, String> _paths = {}; // 段号 → 音频文件路径
  final Set<int> _queued = {}; // 已入队段号（幂等）
  final List<int> _queue = []; // 待识别队列
  final Map<int, String> _results = {}; // 已完成待按序吐出的文字
  final Map<int, String> _failed = {}; // 永久失败但仍可补传的段

  Completer<void>? _idleCompleter;

  /// 串行化切段/停止，避免「切段途中点停止」把同一段入队两次
  Future<void> _chain = Future<void>.value();

  Function(String text)? _onText;
  Function(String msg)? _onError;

  final ValueNotifier<AsrProgress> progress =
      ValueNotifier<AsrProgress>(const AsrProgress());

  bool get isRecording => _recording;
  bool get hasFailedSegments => _failed.isNotEmpty;
  int get recordedSeconds => _recordedSeconds;

  Future<bool> hasPermission() => _recorder.hasPermission();

  /// 回到前台时核对「服务以为在录」与「录音器真的在录」是否一致。
  ///
  /// 这是锁屏/切后台/来电之后最容易被忽略的一步：系统掐掉麦克风时
  /// 不会抛异常、不会回调，Dart 侧 `_recording` 仍然是 true、Timer 也停着，
  /// 界面会一直显示「停止录音」，用户完全不知道已经录不进去了。
  /// 返回 true 表示「刚刚发现录音已经死了，且已收尾为可保存状态」。
  Future<bool> syncRecorderState() async {
    if (_disposed || !_recording) return false;
    bool actuallyRecording;
    try {
      actuallyRecording = await _recorder.isRecording();
    } catch (_) {
      actuallyRecording = false;
    }
    if (actuallyRecording) return false;

    // 录音器已经停了：按「用户点停止」同样的路径收尾，把已有音频送去识别，
    // 这样中断之前录到的内容不会丢。
    debugPrint('[asr] 检测到录音器已被系统中断，自动收尾');
    _recording = false;
    _chunkTimer?.cancel();
    _chunkTimer = null;
    await _releaseKeepAlive();
    final path = _currentPath;
    final idx = _chunkIndex;
    _currentPath = null;
    if (path != null && await File(path).exists()) {
      _enqueue(idx, path);
    }
    _emit();
    _onError?.call('录音已被系统中断（锁屏/来电/后台限制），已录部分已自动送去识别');
    return true;
  }

  /// 把任务串到互斥链上执行，保证切段与停止不会交错
  Future<T> _exclusive<T>(Future<T> Function() task) {
    final result = _chain.then((_) => task());
    _chain = result.then((_) {}, onError: (_) {});
    return result;
  }

  void _emit() {
    if (_disposed) return;
    var done = 0, pending = 0;
    for (final idx in _queued) {
      final st = _stateOf(idx);
      if (st == SegmentState.done) {
        done++;
      } else if (st != SegmentState.failed) {
        pending++;
      }
    }
    progress.value = AsrProgress(
      recordedSeconds: _recordedSeconds,
      segmentNo: _chunkIndex + 1,
      segmentElapsed: _segmentElapsed,
      doneSegments: done,
      pendingSegments: pending,
      failedSegments: _failed.length,
      notice: progress.value.notice,
    );
  }

  SegmentState _stateOf(int idx) {
    if (_failed.containsKey(idx)) return SegmentState.failed;
    if (_results.containsKey(idx)) return SegmentState.done;
    if (_queue.contains(idx)) return SegmentState.uploading;
    return SegmentState.queued;
  }

  void _setNotice(String? n) {
    if (_disposed) return;
    progress.value = progress.value.copyWith(
      notice: n,
      clearNotice: n == null,
    );
  }

  // ───────────────────────── 录音 ─────────────────────────

  /// 开始录音。onText 每识别完一段就回调该段文字（按录制顺序）；onError 报告错误。
  /// Key 未配置时通过 onError 提示并直接返回（不抛异常，页面无需 try/catch 区分）。
  /// 麦克风启动失败时会回滚状态并抛出，调用方据此提示用户。
  Future<void> startRecording({
    required Function(String text) onText,
    required Function(String msg) onError,
  }) async {
    if (_recording || _disposed) return;

    _onText = onText;
    _onError = onError;
    // 系统暂停（来电/其他应用抢麦）时界面必须知道，否则会一直显示在录
    _stateSub ??= _recorder.onStateChanged().listen((state) {
      if (_disposed || !_recording) return;
      if (state == RecordState.pause) {
        _onError?.call('录音被系统暂停（来电或麦克风被占用），恢复后会自动继续；这段时间是静音');
        _emit();
      } else if (state == RecordState.record) {
        _emit();
      }
    });
    _chunkIndex = 0;
    _nextToAppend = 0;
    _recordedSeconds = 0;
    _segmentElapsed = 0;
    _results.clear();
    _queue.clear();
    _queued.clear();
    _paths.clear();
    _failed.clear();
    _setNotice(null);

    final key = await _settings.getAsrKey();
    if (key.isEmpty) {
      onError('请先在「设置」里填写硅基流动 API Key');
      return;
    }

    // 读拾音档位：录音中改设置不影响本次，避免 AudioEffect 中途切换造成音质断层
    _profile = CaptureProfile.fromCode(await _settings.getCaptureProfile());
    debugPrint('[asr] 拾音档位=${_profile.label}，开启：${_profile.activeEffects}');

    await _sweepStaleFiles();

    // 先启动录音，成功了才把 _recording 置 true —— 顺序颠倒会造成
    // 「界面显示正在录音、实际什么都没录」的假状态。
    try {
      await _startNewChunk();
    } catch (e) {
      _recording = false;
      try {
        await _recorder.stop();
      } catch (_) {}
      rethrow;
    }

    _recording = true;
    _emit();
    // 录音期间保持唤醒 + 起前台服务：
    // 课堂场景用户经常锁屏把手机放桌上录一两个小时。
    //   - wakelock：保 CPU 不休眠，防止 Timer 被挂起导致「不再切段」；
    //   - 前台服务：把进程优先级提到最高，防止被系统当后台进程回收。
    // 两者都失败也不阻断录音，只是降级为「仅前台运行可用」，所以要 try 包住。
    try {
      await WakelockPlus.enable();
    } catch (e) {
      debugPrint('[asr] 开启唤醒锁失败: $e');
    }
    try {
      await _foreground.start();
    } catch (e) {
      debugPrint('[asr] 启动前台服务失败: $e');
    }

    _chunkTimer = Timer.periodic(const Duration(seconds: 1), _tick);
  }

  /// 释放「保活手段」：关唤醒锁 + 停前台服务。
  /// 三个退出口（正常停止 / 检测到被中断 / dispose）都走这里，避免漏关导致
  /// 通知栏一直挂着「正在录音」、或者电量被持续消耗。
  /// 所有异常都吞掉：关不掉保活不应该阻断收尾流程。
  Future<void> _releaseKeepAlive() async {
    try {
      await WakelockPlus.disable();
    } catch (e) {
      debugPrint('[asr] 关闭唤醒锁失败: $e');
    }
    try {
      await _foreground.stop();
    } catch (e) {
      debugPrint('[asr] 停止前台服务失败: $e');
    }
  }

  void _tick(Timer _) {
    if (!_recording || _disposed) return;
    _recordedSeconds++;
    _segmentElapsed++;
    _emit();
    // 通知栏文案每 5 秒同步一次就够（每秒更新反而费电，用户锁屏时也看不清）
    if (_recordedSeconds % 5 == 0) {
      unawaited(_foreground.update(
        title: '课堂笔记正在录音 ${AsrProgress.formatSeconds(_recordedSeconds)}',
        text: '第 ${_chunkIndex + 1} 段 · 已转写 ${progress.value.doneSegments} 段',
      ));
    }
    if (_segmentElapsed >= chunkSeconds) {
      _segmentElapsed = 0;
      // 切段放到互斥链上，与停止操作串行
      unawaited(_exclusive(() async {
        await _rotateChunk();
      }));
    }
  }

  /// 录音落应用私有目录（不是系统缓存）：缓存会被系统清理，
  /// 正在录或待补传的段不该被外部删掉。
  Future<Directory> _recordingsDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/recordings');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _startNewChunk() async {
    final dir = await _recordingsDir();
    _currentPath =
        '${dir.path}/classnote_${DateTime.now().microsecondsSinceEpoch}_$_chunkIndex.wav';
    await _recorder.start(_profile.toRecordConfig(), path: _currentPath!);
  }

  /// 切段：停当前段 → 入队 → 立刻开始下一段（录音不中断）
  Future<void> _rotateChunk() async {
    if (!_recording || _disposed) return;
    final path = _currentPath;
    final idx = _chunkIndex;
    _currentPath = null; // 先摘掉，避免停止流程重复处理同一段

    try {
      await _recorder.stop();
    } catch (e) {
      debugPrint('[asr] 切段停止录音失败: $e');
    }

    _chunkIndex++;
    if (path != null) _enqueue(idx, path);

    if (_recording && !_disposed) {
      try {
        await _startNewChunk();
      } catch (e) {
        // 下一段起不来：录音实际上已经断了，必须让界面知道，而不是继续假装在录
        _recording = false;
        _chunkTimer?.cancel();
        _chunkTimer = null;
        _currentPath = null;
        // 录音已断：前台服务/唤醒锁必须一起收掉，否则通知栏一直挂着耗电
        await _releaseKeepAlive();
        _emit();
        _onError?.call('录音被中断（可能是被其他应用占用麦克风），请重新开始');
      }
    }
  }

  /// 入队（幂等）：同一段号只会入队一次
  void _enqueue(int idx, String path) {
    if (!_queued.add(idx)) return;
    _paths[idx] = path;
    _queue.add(idx);
    _emit();
    unawaited(_processQueue());
  }

  /// 停止录音：停掉计时器和当前段，等所有段识别完（或超时）再返回
  /// 用户强制退出、不再等待时调用：把队列里的段标为失败并保留音频文件。
  void abandonPendingSegments() {
    for (final idx in _queue) {
      final path = _paths[idx];
      if (path != null) _failed[idx] = path;
    }
    _queue.clear();
    _queued.clear();
    _emit();
  }

  Future<void> stopRecording({Duration timeout = const Duration(seconds: 120)}) {
    return _exclusive(() => _stopInner(timeout: timeout));
  }

  Future<void> _stopInner({required Duration timeout}) async {
    _chunkTimer?.cancel();
    _chunkTimer = null;
    if (!_recording) return;
    _recording = false;
    // 注意：这里**先不关**前台服务。停止录音时最后一段还没上传完，
    // 此时若用户锁屏离开，进程被回收同样会丢数据。等队列排空后再释放。

    final path = _currentPath;
    final idx = _chunkIndex;
    _currentPath = null;
    if (path != null) {
      try {
        await _recorder.stop();
        _enqueue(idx, path);
      } catch (e) {
        debugPrint('[asr] 停止录音失败: $e');
        _onError?.call('最后一段音频保存失败：$e');
      }
    }
    _emit();

    // 等队列排空。用 Completer 而不是 200ms 忙轮询，并加总超时兜底，
    // 避免任何未预料的异常让界面永久卡在「正在转写」。
    if (_queue.isEmpty && !_processing) {
      await _releaseKeepAlive();
      return;
    }

    // 通知改成「正在转写」，让用户知道还可以安全锁屏
    unawaited(_foreground.update(
      title: '正在转写最后几段…',
      text: '转写完成后会自动结束，期间可安全锁屏',
    ));

    _idleCompleter ??= Completer<void>();
    try {
      await _idleCompleter!.future.timeout(timeout);
    } on TimeoutException {
      // 还在队列里的段转成「失败」，否则界面上没有补传入口，
      // 用户只看到一句「转写完成」，实际缺了几分钟
      for (final idx in _queue) {
        final path = _paths[idx];
        if (path != null) _failed[idx] = path;
      }
      _queue.clear();
      _queued.clear();
      _emit();
      _onError?.call('部分分段转写超时，已完成的文字已保留，剩余可在下方补传');
    } finally {
      _idleCompleter = null;
      // 收尾：无论成功还是超时，都要把前台服务和唤醒锁释放掉
      await _releaseKeepAlive();
    }
  }

  // ─────────────────────── 识别队列 ───────────────────────

  /// 顺序处理识别队列：保证文字按录制顺序回调。
  /// 注意 finally：_processing 必须复位，否则一次异常就让停止流程永久卡住。
  Future<void> _processQueue() async {
    if (_processing || _disposed) return;
    _processing = true;
    try {
      while (_queue.isNotEmpty) {
        if (_disposed) break;
        final idx = _queue.removeAt(0);
        final path = _paths[idx];
        if (path == null) {
          _queued.remove(idx);
          continue;
        }

        _emit();
        String? text;
        String? error;
        var fatal = false;

        for (var attempt = 0; attempt <= _retryDelays.length; attempt++) {
          try {
            text = await recognize(path);
            break;
          } on AsrException catch (e) {
            error = e.message;
            fatal = !e.retryable;
            if (fatal || attempt == _retryDelays.length) break;
            _setNotice(
                '第 ${idx + 1} 段识别失败，正在重试 ${attempt + 1}/${_retryDelays.length}');
            await Future<void>.delayed(_retryDelays[attempt]);
            if (_disposed) break;
          } catch (e) {
            // 非预期异常：不重试，但必须留下痕迹而不是静默吞掉
            error = e.toString().replaceFirst('Exception: ', '');
            fatal = true;
            break;
          }
        }
        _setNotice(null);
        if (_disposed) break;

        if (text != null && text.isNotEmpty) {
          _results[idx] = text;
          _failed.remove(idx);
          await _deleteQuietly(path);
          _paths.remove(idx);
        } else {
          // 永久失败：保留文件以便补传，同时在正文里留下可见占位，
          // 让用户知道「这里缺了一段」，而不是静默少 60 秒内容。
          _results[idx] = '〔第 ${idx + 1} 段语音识别失败'
              '${fatal ? '' : '（多次重试未成功）'}：${error ?? '未知原因'}〕';
          _failed[idx] = path;
          _onError?.call('第 ${idx + 1} 段识别失败：${error ?? '未知原因'}');
        }

        // 按序吐出所有已就绪的段
        while (_results.containsKey(_nextToAppend)) {
          final t = _results.remove(_nextToAppend)!;
          if (t.isNotEmpty) _onText?.call(t);
          _nextToAppend++;
        }
        _emit();
      }
    } finally {
      _processing = false;
      _emit();
      if (_queue.isEmpty) {
        final c = _idleCompleter;
        _idleCompleter = null;
        if (c != null && !c.isCompleted) c.complete();
      }
    }
  }

  /// 补传所有此前失败的段（用户点「重试失败段」）
  Future<void> retryFailedSegments() async {
    if (_failed.isEmpty || _disposed || _retrying) return;
    final items = Map<int, String>.from(_failed);
    _failed.clear();
    _retrying = true;
    _emit();
    try {
      for (final entry in items.entries) {
        if (_disposed) break;
        final idx = entry.key;
        final path = entry.value;
        _setNotice('正在补传第 ${idx + 1} 段…');
        try {
          String? text;
          for (var attempt = 0; attempt <= _retryDelays.length; attempt++) {
            try {
              text = await recognize(path);
              break;
            } on AsrException catch (e) {
              if (!e.retryable || attempt == _retryDelays.length) rethrow;
              await Future<void>.delayed(_retryDelays[attempt]);
              if (_disposed) return;
            }
          }
          if (text == null) throw AsrException('补传失败，可再试一次');
          if (_disposed) return;
          // 该段原本在正文里已留下占位，补传结果明确标注段号追加到末尾，
          // 用户一眼能看出它属于哪里，不会误以为顺序错乱。
          _onText?.call('〔补传 第 ${idx + 1} 段〕\n$text');
          _queued.remove(idx);
          await _deleteQuietly(path);
          _paths.remove(idx);
        } on AsrException catch (e) {
          _failed[idx] = path;
          _onError?.call('第 ${idx + 1} 段补传仍失败：${e.message}');
        } catch (e) {
          _failed[idx] = path;
          _onError?.call('第 ${idx + 1} 段补传仍失败：$e');
        }
        _emit();
      }
    } finally {
      _retrying = false;
      _setNotice(null);
      _emit();
    }
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 清掉上次崩溃/强杀遗留的临时音频，避免缓存目录无限增长
  Future<void> _sweepStaleFiles() async {
    try {
      final dir = await _recordingsDir();
      final cutoff =
          DateTime.now().subtract(const Duration(hours: 24)).millisecondsSinceEpoch;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith('classnote_') || !name.endsWith('.wav')) continue;
        try {
          final st = await entity.stat();
          if (st.modified.millisecondsSinceEpoch < cutoff) {
            await entity.delete();
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[asr] 清理旧临时文件失败: $e');
    }
  }

  // ─────────────────────── 网络 ───────────────────────

  /// 把一段音频转成文字。
  /// 硅基流动 whisper 式接口：POST multipart/form-data，字段 file + model，返回 {"text": ...}。
  /// 失败抛 AsrException，由调用方决定是否重试。注意：这里**不删除文件**，
  /// 删除交给调用方，否则重试时会发现文件已经没了。
  Future<String> recognize(String filePath) async {
    final apiKey = await _settings.getAsrKey();
    if (apiKey.isEmpty) {
      throw AsrException('请先在「设置」里填写硅基流动 API Key', retryable: false);
    }

    final file = File(filePath);
    if (!await file.exists()) {
      throw AsrException('录音文件不存在', retryable: false);
    }

    final uri = Uri.parse(AppConfig.asrBaseUrl);
    // 模型名从设置里读，用户可以在设置页切换 SenseVoiceSmall / TeleSpeechASR 做对比。
    final model = await _settings.getAsrModel();
    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $apiKey'
      // 注意：硅基流动这个接口只接受 file 和 model 两个字段，
      // 不要试图加 hotwords / prompt / language，官方文档里没有这些参数。
      ..fields['model'] = model
      ..files.add(await http.MultipartFile.fromPath('file', filePath,
          filename: 'audio.wav'));

    final client = http.Client();
    late final http.Response response;
    try {
      final streamed = await client
          .send(request)
          .timeout(const Duration(seconds: 120));
      // 响应体也要单独设限：服务端发完头后卡住会让队列永久阻塞
      response = await http.Response.fromStream(streamed)
          .timeout(const Duration(seconds: 60));
    } on TimeoutException {
      // close 会中止底层连接，避免超时后重试把同一段再并发发一份
      client.close();
      throw AsrException('上传/响应超时（弱网），可重试');
    } catch (e) {
      client.close();
      throw AsrException('网络请求失败，请检查网络（$e）');
    } finally {
      client.close();
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw AsrException('硅基流动 API Key 无效或未实名，请到设置里检查 Key',
          retryable: false, statusCode: response.statusCode);
    }
    if (response.statusCode == 429) {
      throw AsrException('请求太频繁，稍后自动重试', statusCode: 429);
    }
    if (response.statusCode >= 500) {
      throw AsrException('服务端错误（${response.statusCode}），稍后自动重试',
          statusCode: response.statusCode);
    }
    if (response.statusCode != 200) {
      String detail = response.body;
      try {
        final err = jsonDecodeOrNull(response.body);
        if (err != null) detail = '${err['message'] ?? err['data'] ?? response.body}';
      } catch (_) {}
      final s = detail;
      throw AsrException(
        '识别失败（${response.statusCode}）：${s.length > 120 ? s.substring(0, 120) : s}',
        retryable: false,
        statusCode: response.statusCode,
      );
    }

    final err = jsonDecodeOrNull(response.body);
    if (err == null) {
      // 200 但不是 JSON：校园网认证页/网关拦截/字段变更，重试有意义
      throw AsrException('识别接口返回了非 JSON（可能被网关拦截），稍后自动重试',
          retryable: true, statusCode: response.statusCode);
    }
    final text = err['text'] as String?;
    if (text == null) {
      throw AsrException('识别结果缺少 text 字段，稍后自动重试',
          retryable: true, statusCode: response.statusCode);
    }
    // 真空结果（这段没人说话）不算失败：返回空串，不占位、不进失败列表
    return text.trim();
  }

  static Map<String, dynamic>? jsonDecodeOrNull(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// 释放资源：取消计时器、清空队列、断掉回调，并停止/销毁录音器。
  /// 页面 dispose 时调用；置空回调可防止上传结果打到已销毁的 State 上。
  Future<void> dispose() async {
    await _stateSub?.cancel();
    _stateSub = null;
    _disposed = true;
    _chunkTimer?.cancel();
    _chunkTimer = null;
    _onText = null;
    _onError = null;
    _queue.clear();
    _queued.clear();
    _paths.clear();
    _results.clear();
    _failed.clear();
    final c = _idleCompleter;
    _idleCompleter = null;
    if (c != null && !c.isCompleted) c.complete();
    try {
      if (await _recorder.isRecording()) await _recorder.stop();
    } catch (_) {}
    await _releaseKeepAlive();
    try {
      await _recorder.dispose();
    } catch (_) {}
  }
}
