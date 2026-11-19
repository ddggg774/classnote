// lib/services/foreground_service.dart
// 前台服务封装：录音期间起一个 Android 前台服务 + 常驻通知。
//
// 【为什么要这个】
// 光有 wakelock 只能保「CPU 不休眠」，挡不住系统在后台回收进程。
// 课堂场景用户经常锁屏把手机放桌上录一两个小时，没有前台服务，
// 进程随时可能被清理，而录音（在主 isolate 里跑）会随之消失。
//
// 【为什么不用 TaskHandler 在 isolate 里录音】
// flutter_foreground_task 的 TaskHandler 跑在**独立 isolate**。
// 录音器（record 插件）一旦在 isolate 里 start，会和主 isolate 抢麦克风，
// 而且两个 isolate 之间同步录音状态非常麻烦。
// 所以这里的策略是：**前台服务只负责「保活 + 显示通知」，录音仍留在主 isolate**。
// 好处是改动面极小、不碰已经验证过的录音逻辑；代价是极端情况下
// 主 isolate 仍可能被挂起 —— 但 Android 对前台服务的进程优先级最高，
// 实践中足够覆盖「锁屏两小时」这个场景。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// 前台服务控制器（单例）。所有异常都吞掉并打日志：
/// 前台服务起不来不能影响录音本身，只能降级为「仅 wakelock」。
class ForegroundRecordingService {
  ForegroundRecordingService._internal();
  static final ForegroundRecordingService _instance =
      ForegroundRecordingService._internal();
  factory ForegroundRecordingService() => _instance;

  static const int _serviceId = 8848;
  bool _initialized = false;
  bool _running = false;

  bool get isRunning => _running;

  /// 初始化通知渠道与任务选项。只需调用一次。
  void init() {
    if (_initialized) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'classnote_recording',
        channelName: '录音中',
        channelDescription: '课堂笔记正在录音时显示，用于保证录音不被系统中断',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        // 静音、不震动、不亮屏：录音是长时间后台行为，通知不该打扰用户
        enableVibration: false,
        playSound: false,
        showWhen: false,
        onlyAlertOnce: true,
        visibility: NotificationVisibility.VISIBILITY_PUBLIC,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // 不需要周期回调（录音在主 isolate），设成较低频率减少空转
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
    _initialized = true;
  }

  /// 请求通知权限（Android 13+ 必须）。返回是否已授权。
  Future<bool> ensureNotificationPermission() async {
    try {
      final permission =
          await FlutterForegroundTask.checkNotificationPermission();
      if (permission != NotificationPermission.granted) {
        final result =
            await FlutterForegroundTask.requestNotificationPermission();
        return result == NotificationPermission.granted;
      }
      return true;
    } catch (e) {
      debugPrint('[fg] 请求通知权限失败: $e');
      return false;
    }
  }

  /// 启动前台服务。返回 true 表示真的起来了（失败也只是降级，不阻断录音）。
  Future<bool> start({String title = '课堂笔记正在录音'}) async {
    if (_running) return true;
    init();
    try {
      // 已经授权过就不再打扰用户；没授权则请求（Android 13+）
      await ensureNotificationPermission();

      final result = await FlutterForegroundTask.startService(
        serviceId: _serviceId,
        serviceTypes: const [ForegroundServiceTypes.microphone],
        notificationTitle: title,
        notificationText: '点开可返回 App · 录音期间请勿强制关闭',
      );
      if (result is ServiceRequestSuccess) {
        _running = true;
        return true;
      }
      final failure = result as ServiceRequestFailure;
      debugPrint('[fg] 启动前台服务失败: ${failure.error}');
      return false;
    } catch (e) {
      debugPrint('[fg] 启动前台服务异常: $e');
      return false;
    }
  }

  /// 更新通知文案（显示已录时长 / 已完成段数）
  Future<void> update({String? title, String? text}) async {
    if (!_running) return;
    try {
      final result = await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
      );
      if (result is ServiceRequestFailure) {
        debugPrint('[fg] 更新通知失败: ${result.error}');
      }
    } catch (e) {
      debugPrint('[fg] 更新通知异常: $e');
    }
  }

  /// 停止前台服务
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    try {
      await FlutterForegroundTask.stopService();
    } catch (e) {
      debugPrint('[fg] 停止前台服务异常: $e');
    }
  }
}
