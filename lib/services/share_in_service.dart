// lib/services/share_in_service.dart
// 接收其他 App 分享来的文本（主要用于把 DeepSeek 等改写的笔记带回来）。
//
// 冷启动：文本随 Intent 进来，由 Android 侧暂存，这里拉取一次；
// 热启动：Android 侧通过 onSharedText 推过来。
// 只做「收文本」，落哪个笔记由界面决定。
import 'dart:async';

import 'package:flutter/services.dart';

class ShareInService {
  ShareInService._();
  static final ShareInService instance = ShareInService._();

  static const MethodChannel _channel = MethodChannel('classnote/share_in');

  final List<String> _pending = [];
  bool _inited = false;
  final StreamController<String> _incoming = StreamController.broadcast();

  /// 新分享的文本流（页面在前台时用）
  Stream<String> get incoming => _incoming.stream;

  Future<void> ensureInit() async {
    if (_inited) return;
    _inited = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSharedText') {
        final text = call.arguments as String?;
        if (text != null && text.trim().isNotEmpty) {
          _pending.add(text.trim());
          _incoming.add(text.trim());
        }
      }
      return null;
    });
    final initial = await _channel.invokeMethod<String>('getPendingText');
    if (initial != null && initial.trim().isNotEmpty) {
      _pending.add(initial.trim());
      _incoming.add(initial.trim());
    }
  }

  /// 取走待导入文本（取一次就清空，避免重复导入）
  String? takePending() {
    if (_pending.isEmpty) return null;
    return _pending.removeAt(0);
  }
}
