// lib/services/mind_graph_exporter.dart
// 把详细导图导出成各种格式。全部是纯字符串转换，不依赖 Flutter，
// 因此可以直接写单元测试（这也是选择这几种格式的原因之一）。
//
// 支持的格式：
//   markdown —— 缩进列表，XMind / 幕布 / MindMeister 都能直接粘贴导入
//   markmap  —— 生成自带交互的 HTML（手机浏览器打开即可折叠浏览）
//   mermaid  —— 纯文本 mindmap，适合 Obsidian / Notion / GitHub
//   opml     —— 标准大纲格式，幕布、MindMeister、OmniOutliner 可直接导入
//   json     —— 原始结构，给程序用
//
// 为什么没有直接产出 .xmind：.xmind 是 zip 包（content.json + manifest + metadata），
// Flutter 里要额外引 archive 依赖、还要对齐它的版本格式，容易出错。
// Markdown/OPML 的导入体验已经足够好，先用这两条路径。
import 'dart:convert';

import '../models/mind_graph.dart';

class MindGraphExporter {
  const MindGraphExporter._();

  // ───────────────────── Markdown 缩进列表 ─────────────────────

  /// 导出的正文是「根 → 一级分支 → …」，每级 2 空格缩进。
  /// 节点上会带关系、标记、来源，但都压在行内，保证仍然是合法的 Markdown 列表。
  static String toMarkdown(MindGraph graph) {
    final b = StringBuffer();
    b.writeln('# ${graph.root}');
    b.writeln();
    b.writeln('> 共 ${graph.totalNodes} 个节点，最深 ${graph.maxDepth} 级');
    b.writeln();
    for (final branch in graph.branches) {
      _writeNode(b, branch, 0);
    }
    final missing = graph.missingRequiredBranches;
    if (missing.isNotEmpty) {
      b.writeln();
      b.writeln('---');
      b.writeln();
      b.writeln('**以下分支未提及：** ${missing.join('、')}');
    }
    return b.toString();
  }

  static void _writeNode(StringBuffer b, MindGraphNode node, int level) {
    final indent = '  ' * level;
    final badge = _badge(node);
    final rel = node.relation != null ? ' 〔${node.relation}〕' : '';
    b.writeln('$indent- $badge${node.title}$rel');

    for (final d in node.details) {
      b.writeln('$indent  - $d');
    }
    if (node.source != null) {
      b.writeln('$indent  - 来源：${node.source}');
    }
    for (final child in node.children) {
      _writeNode(b, child, level + 1);
    }
  }

  static String _badge(MindGraphNode node) {
    final s = node.mark.symbol;
    return s.isEmpty ? '' : '$s ';
  }

  // ───────────────────── Markmap HTML ─────────────────────

  /// 生成一个自包含的 HTML：直接引 Markmap 的 CDN，
  /// 手机浏览器打开就能折叠浏览，不用装任何东西。
  static String toMarkmapHtml(MindGraph graph) {
    // Markmap 吃的是 Markdown，所以直接复用 toMarkdown，但要
    // 去掉首行大标题（它会作为根节点重复出现一次）。
    final md = toMarkdown(graph);
    // 注意：body 是通过 jsonEncode 注入到 JS 里的，不需要额外做 HTML 转义；
    // 只有 <title> 这种直接写进 HTML 文本的地方要转义。
    final body = md.startsWith('# ')
        ? md.substring(md.indexOf('\n') + 1).trimLeft()
        : md;
    final title = const HtmlEscape(HtmlEscapeMode.element).convert(graph.root);

    return '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title · 课堂思维导图</title>
<style>
  html,body{margin:0;height:100%;font-family:-apple-system,"PingFang SC","Microsoft YaHei",sans-serif}
  #mindmap{width:100%;height:100%}
  .hint{position:fixed;left:12px;bottom:12px;background:rgba(0,0,0,.65);color:#fff;
        padding:6px 10px;border-radius:8px;font-size:12px;z-index:9}
</style>
</head>
<body>
<svg id="mindmap"></svg>
<div class="hint">双指缩放 · 单指拖动 · 点圆点折叠</div>
<script src="https://cdn.jsdelivr.net/npm/d3@7"></script>
<script src="https://cdn.jsdelivr.net/npm/markmap-view@0.15"></script>
<script src="https://cdn.jsdelivr.net/npm/markmap-lib@0.15"></script>
<script>
  const md = ${jsonEncode(body)};
  const {Transformer} = window.markmap;
  const transformer = new Transformer();
  const {root} = transformer.transform(md);
  window.markmap.Markmap.create('#mindmap', {colorFreezeLevel: 2}, root);
</script>
</body>
</html>''';
  }

  // ───────────────────── Mermaid mindmap ─────────────────────

  /// Mermaid 的 mindmap 语法靠缩进表达层级，节点文本里有括号会破坏语法，
  /// 所以这里要把标题做一次转义。
  static String toMermaid(MindGraph graph) {
    final b = StringBuffer();
    b.writeln('mindmap');
    b.writeln('  root((${_mermaidSafe(graph.root)}))');
    for (final branch in graph.branches) {
      _writeMermaid(b, branch, 2);
    }
    return b.toString();
  }

  static void _writeMermaid(StringBuffer b, MindGraphNode node, int level) {
    final indent = '  ' * level;
    final mark = node.mark == NodeMark.none ? '' : '${node.mark.symbol} ';
    final rel = node.relation != null ? '〔${node.relation}〕' : '';
    b.writeln('$indent${_mermaidSafe('$mark${node.title}$rel')}');
    for (final child in node.children) {
      _writeMermaid(b, child, level + 1);
    }
  }

  /// Mermaid mindmap 里这些字符有语法意义，替换成全角避免破坏结构
  static String _mermaidSafe(String s) {
    return s
        .replaceAll('(', '（')
        .replaceAll(')', '）')
        .replaceAll('[', '【')
        .replaceAll(']', '】')
        .replaceAll('{', '｛')
        .replaceAll('}', '｝')
        .replaceAll('::', '：');
  }

  // ───────────────────── OPML ─────────────────────

  /// OPML 是标准大纲格式，幕布 / MindMeister / OmniOutliner 都能直接导入。
  /// 节点正文（details）会作为子节点挂上去，保证信息不丢。
  static String toOpml(MindGraph graph) {
    final b = StringBuffer();
    b.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    b.writeln('<opml version="2.0">');
    b.writeln('  <head>');
    b.writeln('    <title>${_xmlEscape(graph.root)}</title>');
    b.writeln('  </head>');
    b.writeln('  <body>');
    b.writeln('    <outline text="${_xmlEscape(graph.root)}">');
    for (final branch in graph.branches) {
      _writeOpml(b, branch, 3);
    }
    b.writeln('    </outline>');
    b.writeln('  </body>');
    b.writeln('</opml>');
    return b.toString();
  }

  static void _writeOpml(StringBuffer b, MindGraphNode node, int level) {
    final indent = '  ' * level;
    final label = '${_badge(node)}${node.title}'
        '${node.relation != null ? ' 〔${node.relation}〕' : ''}';
    final hasChildren = node.details.isNotEmpty || node.children.isNotEmpty;
    if (!hasChildren) {
      b.writeln('$indent<outline text="${_xmlEscape(label)}"/>');
      return;
    }
    b.writeln('$indent<outline text="${_xmlEscape(label)}">');
    for (final d in node.details) {
      b.writeln('$indent  <outline text="${_xmlEscape(d)}"/>');
    }
    for (final child in node.children) {
      _writeOpml(b, child, level + 1);
    }
    b.writeln('$indent</outline>');
  }

  static String _xmlEscape(String s) => const HtmlEscape(HtmlEscapeMode.attribute)
      .convert(s)
      // HtmlEscape 不处理单引号，OPML 用双引号包属性，这里统一转掉
      .replaceAll("'", '&#39;');

  // ───────────────────── JSON ─────────────────────

  static String toJson(MindGraph graph) {
    return const JsonEncoder.withIndent('  ').convert(graph.toJson());
  }

  /// 给 UI 用的格式清单（文件名后缀 + 显示名）
  static const List<({String key, String label, String ext})> formats = [
    (key: 'md', label: 'Markdown（可导入 XMind）', ext: 'md'),
    (key: 'markmap', label: '交互网页（手机可看）', ext: 'html'),
    (key: 'mermaid', label: 'Mermaid 文本', ext: 'mmd'),
    (key: 'opml', label: 'OPML 大纲', ext: 'opml'),
    (key: 'json', label: 'JSON 结构', ext: 'json'),
  ];

  static String render(MindGraph graph, String key) {
    switch (key) {
      case 'md':
        return toMarkdown(graph);
      case 'markmap':
        return toMarkmapHtml(graph);
      case 'mermaid':
        return toMermaid(graph);
      case 'opml':
        return toOpml(graph);
      case 'json':
        return toJson(graph);
      default:
        return toMarkdown(graph);
    }
  }

  static String extOf(String key) {
    for (final f in formats) {
      if (f.key == key) return f.ext;
    }
    return 'txt';
  }
}