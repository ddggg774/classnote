// test/mind_graph_test.dart
// 详细导图的数据模型 + 四种导出格式测试。
// 重点覆盖：
//   ① 3–5 级嵌套能正确解析、深度统计正确；
//   ② 关系/标记/来源字段不丢；
//   ③ 11 个固定分支缺失能被识别（用于界面提示"未提及"）；
//   ④ 四种导出格式都是合法结构（Markdown 缩进、OPML 闭合、Mermaid 转义）；
//   ⑤ 旧数据降级不崩。
import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/models/mind_graph.dart';
import 'package:classnote/models/note.dart';
import 'package:classnote/services/mind_graph_exporter.dart';

/// 构造一棵 3 级样例树
MindGraph buildSample() {
  return MindGraph.fromJson({
    'root': '高等数学 第三讲',
    'branches': [
      {
        'id': 'b0',
        'title': '知识点结构',
        'children': [
          {
            'id': 'b0-1',
            'title': '极限的 ε-δ 定义',
            'relation': '包含',
            'details': ['定义：对任意 ε>0，存在 δ>0', '条件：f(x) 在 x0 的去心邻域有定义'],
            'source': '03:20「我们今天先看极限的严格定义」',
            'mark': 'key',
            'children': [
              {
                'id': 'b0-1-1',
                'title': '适用条件：函数需在去心邻域有定义',
                'relation': '推导',
                'details': ['否则 δ 无法取到'],
                'children': [
                  {
                    'id': 'b0-1-1-1',
                    'title': '反例：分段函数在断点处',
                    'relation': '对比',
                    'mark': 'pitfall',
                  }
                ]
              }
            ]
          }
        ]
      },
      {
        'id': 'b1',
        'title': '公式/定理',
        'children': [
          {
            'id': 'b1-1',
            'title': '洛必达法则',
            'relation': '推导',
            'details': ['lim f/g = lim f\'/g\'', '适用：0/0 或 ∞/∞ 型'],
            'mark': 'exam',
            'source': '08:05「这个是必考的」',
          }
        ]
      },
      {
        'id': 'b2',
        'title': '待确认清单',
        'children': [
          {
            'id': 'b2-1',
            'title': '例题 2 分母转写不清',
            'mark': 'unconfirmed',
            'details': ['原文疑似"x 减一"但听不清'],
          }
        ]
      }
    ],
  });
}

void main() {
  group('MindGraph 解析', () {
    test('多级嵌套与深度统计正确', () {
      final g = buildSample();
      expect(g.root, '高等数学 第三讲');
      expect(g.branches.length, 3);
      // 知识点结构分支：自身 + 1 子 + 1 孙 + 1 曾孙 = 4
      expect(g.branches[0].totalCount, 4);
      expect(g.maxDepth, 4);
    });

    test('关系、标记、来源字段都被保留', () {
      final g = buildSample();
      final node = g.branches[0].children[0];
      expect(node.title, '极限的 ε-δ 定义');
      expect(node.relation, '包含');
      expect(node.mark, NodeMark.key);
      expect(node.source, contains('03:20'));
      expect(node.details.length, 2);
    });

    test('节点标题不是占位词（验收：不能只写"重点"/"例题1"）', () {
      final g = buildSample();
      final weak = RegExp(r'^(重点|难点|例题\d*|要点\d*|未命名)$');
      void walk(MindGraphNode n) {
        expect(weak.hasMatch(n.title.trim()), isFalse,
            reason: '节点标题过于笼统：${n.title}');
        n.children.forEach(walk);
      }

      g.branches.forEach(walk);
    });

    test('缺失的固定分支能被识别出来', () {
      final g = buildSample();
      final missing = g.missingRequiredBranches;
      // 样例只给了 3 个分支，其余 8 个应被列为缺失
      expect(missing.length, MindGraph.requiredBranches.length - 3);
      expect(missing, contains('学习目标'));
      expect(missing, isNot(contains('知识点结构')));
    });

    test('JSON 往返一致', () {
      final g = buildSample();
      final restored = MindGraph.tryDecode(g.encode())!;
      expect(restored.totalNodes, g.totalNodes);
      expect(restored.maxDepth, g.maxDepth);
      expect(restored.branches[0].children[0].mark, NodeMark.key);
    });

    test('空 children 的节点不会崩', () {
      final g = MindGraph.fromJson({
        'root': 'r',
        'branches': [
          {'title': '未提及', 'children': []}
        ]
      });
      expect(g.branches.length, 1);
      expect(g.branches.first.children, isEmpty);
    });

    test('坏 JSON 返回 null', () {
      expect(MindGraph.tryDecode('not json'), isNull);
      expect(MindGraph.tryDecode(''), isNull);
      expect(MindGraph.tryDecode(null), isNull);
    });
  });

  group('旧数据降级', () {
    test('两层 MindMap 能转成 graph，不丢节点', () {
      final legacy = MindMapData(
        root: '老课程',
        nodes: [
          MindNode(topic: '极限', children: ['定义', '性质']),
        ],
      );
      final g = MindGraph.fromLegacyMindMap(legacy);
      expect(g.root, '老课程');
      expect(g.branches.length, 1);
      expect(g.branches.first.title, '极限');
      expect(g.branches.first.children.length, 2);
      // 降级后只有两层，页面据此提示"重新总结可获得详细导图"
      expect(g.maxDepth, 2);
    });
  });

  group('导出格式', () {
    test('Markdown 用 2 空格缩进且含关系与来源', () {
      final md = MindGraphExporter.toMarkdown(buildSample());
      expect(md, startsWith('# 高等数学 第三讲'));
      expect(md, contains('- ')); // 列表项
      expect(md, contains('  - ')); // 二级缩进
      expect(md, contains('〔包含〕'));
      expect(md, contains('来源：'));
      expect(md, contains('★')); // 标记
      // 缺失分支应有提示
      expect(md, contains('未提及'));
    });

    test('Markdown 能被 XMind/幕布这类工具按缩进识别为层级', () {
      final md = MindGraphExporter.toMarkdown(buildSample());
      final lines = md.split('\n');
      // 找出「极限的 ε-δ 定义」这一行和它的子行，确认缩进递进
      final idx = lines.indexWhere((l) => l.contains('极限的 ε-δ 定义'));
      expect(idx, greaterThan(0));
      final indentOfParent = lines[idx].indexOf('- ');
      final childLine = lines
          .skip(idx + 1)
          .firstWhere((l) => l.contains('- '), orElse: () => '');
      if (childLine.isNotEmpty) {
        expect(childLine.indexOf('- '), greaterThan(indentOfParent));
      }
    });

    test('Markmap HTML 是完整文档且含数据', () {
      final html = MindGraphExporter.toMarkmapHtml(buildSample());
      expect(html, contains('<!DOCTYPE html>'));
      expect(html, contains('markmap'));
      expect(html, contains('</html>'));
      expect(html, contains('极限的 ε-δ 定义'));
    });

    test('Mermaid 首行是 mindmap 且节点文本里的括号被转义', () {
      final mm = MindGraphExporter.toMermaid(buildSample());
      final lines = mm.split('\n');
      expect(lines.first.trim(), 'mindmap');
      // 第 2 行的 root((...)) 是 Mermaid 自己的语法，跳过它再检查节点文本
      final body = lines.skip(2).join('\n');
      expect(body.contains('('), isFalse,
          reason: '节点文本里的半角括号会破坏 Mermaid 语法');
      expect(body.contains(')'), isFalse);
      expect(mm, contains('洛必达法则'));
    });

    test('OPML 结构闭合且转义正确', () {
      final opml = MindGraphExporter.toOpml(buildSample());
      expect(opml, contains('<?xml version="1.0" encoding="UTF-8"?>'));
      expect(opml, contains('<opml version="2.0">'));
      expect(opml.trimRight(), endsWith('</opml>'));
      // 只统计「有闭合标签的开标签」，自闭合的 <outline ... /> 不算
      final open = RegExp(r'<outline [^>]*[^/\s]>').allMatches(opml).length;
      final close = '</outline>'.allMatches(opml).length;
      expect(open, close,
          reason: 'OPML 开标签($open)与闭标签($close)数量不一致');
      expect(open, greaterThan(0));
    });

    test('OPML 转义双引号与尖括号', () {
      final g = MindGraph.fromJson({
        'root': '含 "引号" 与 <尖括号>',
        'branches': [
          {'title': 'a & b', 'children': []}
        ]
      });
      final opml = MindGraphExporter.toOpml(g);
      expect(opml, isNot(contains('"引号"')));
      expect(opml.contains('&lt;'), isTrue);
      expect(opml.contains('&amp;'), isTrue);
    });

    test('JSON 导出可被重新解析', () {
      final json = MindGraphExporter.toJson(buildSample());
      final back = MindGraph.tryDecode(json)!;
      expect(back.totalNodes, buildSample().totalNodes);
    });

    test('render() 覆盖全部格式且不抛异常', () {
      final g = buildSample();
      for (final f in MindGraphExporter.formats) {
        final out = MindGraphExporter.render(g, f.key);
        expect(out.trim(), isNotEmpty, reason: '格式 ${f.key} 输出为空');
        expect(MindGraphExporter.extOf(f.key), f.ext);
      }
    });

    test('未知格式回落到 Markdown', () {
      final out = MindGraphExporter.render(buildSample(), 'unknown');
      expect(out, startsWith('# '));
      expect(MindGraphExporter.extOf('unknown'), 'txt');
    });
  });
}