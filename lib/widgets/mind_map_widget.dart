// lib/widgets/mind_map_widget.dart
// 思维导图组件：把 MindMapData 画成"中心主题 -> 要点 -> 子点"的树状图。
// 用纯 Flutter 组件实现（左侧中心节点 + 右侧逐级展开），不依赖第三方绘图库。
// 整个内容包在 RepaintBoundary 里，方便调用方把导图导出为图片。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';

import '../models/note.dart';

class MindMapWidget extends StatelessWidget {
  final MindMapData data;

  /// 截图用的 GlobalKey，需要导出图片时由调用方创建并传入。
  /// 通过它获取 RepaintBoundary 再调用 [exportPng]。
  final GlobalKey? captureKey;

  const MindMapWidget({super.key, required this.data, this.captureKey});

  /// 把当前思维导图渲染成 PNG 字节（背景为白色，适配分享/保存）。
  /// 需先传入 [captureKey]；失败时抛异常。
  ///
  /// [pixelRatio] 会按内容尺寸自动下调：导图高 2000–4000 逻辑像素时，
  /// 固定 3 倍会请求 6000–12000 物理像素宽的位图（数百 MB），中低端机直接 OOM。
  /// 这里把「物理像素上限」钉在 [maxPixels] 内，长图自动降到 2 倍甚至更低。
  /// [ui.Image] 必须 dispose，否则每次导出都会泄漏一块原生内存。
  static Future<Uint8List> exportPng(GlobalKey captureKey,
      {double pixelRatio = 3.0, double maxPixels = 4000}) async {
    final boundary =
        captureKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) {
      throw Exception('导图尚未渲染完成，请稍后重试');
    }
    final size = boundary.size;
    var ratio = pixelRatio;
    final longest = size.width > size.height ? size.width : size.height;
    if (longest > 0) {
      // 保证最长边不超过 maxPixels 物理像素，同时最低不低于 1.0（否则文字发虚）
      final allowed = maxPixels / longest;
      if (allowed < ratio) ratio = allowed.clamp(1.0, pixelRatio);
    }
    final image = await boundary.toImage(pixelRatio: ratio);
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw Exception('导出图片失败');
      }
      return byteData.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 外层 SingleChildScrollView 负责滚动，RepaintBoundary 包住全部内容，
    // 保证导出时能截到完整导图（即使超出屏幕可视区）。
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: RepaintBoundary(
        key: captureKey,
        child: Container(
          color: Colors.white, // 导出图片底色为白，避免透明背景看不清
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 中心主题
              _CenterNode(text: data.root),
              const SizedBox(height: 12),
              // 连接线（中心向下）
              const Center(
                child: SizedBox(
                  height: 20,
                  child: VerticalDivider(width: 2, color: Colors.indigo),
                ),
              ),
              const SizedBox(height: 12),
              // 逐个要点
              ...data.nodes.map((node) => _BranchCard(node: node)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 中心主题节点
class _CenterNode extends StatelessWidget {
  final String text;
  const _CenterNode({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Colors.indigo, Colors.indigoAccent]),
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(color: Colors.indigo.withValues(alpha: 0.3), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
      ),
    );
  }
}

/// 一个要点分支卡片：标题 + 若干子点
class _BranchCard extends StatelessWidget {
  final MindNode node;
  const _BranchCard({required this.node});

  @override
  Widget build(BuildContext context) {
    final color = Colors.teal.shade400;       // Color 类型：用于边框/图标
    final darkColor = Colors.teal.shade800;   // MaterialColor 的深色调：用于文字
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border(left: BorderSide(color: color, width: 4)),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 要点标题
          Row(
            children: [
              Icon(Icons.chevron_right, color: color),
              const SizedBox(width: 4),
              Expanded(
                child: Text(node.topic,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: darkColor)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 子点列表
          ...node.children.map((child) => Padding(
                padding: const EdgeInsets.only(left: 28, top: 4, bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.fiber_manual_record, size: 8, color: Colors.grey),
                    const SizedBox(width: 8),
                    Expanded(child: Text(child, style: const TextStyle(fontSize: 14, height: 1.5))),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}
