// lib/services/skill_registry.dart
// 技能注册表：内置技能定义 + 启停状态 + 按课程筛选。
//
// 【为什么内置技能写死在代码里】
// 技能包含提示词片段，是产品定义的一部分。存数据库的话：
//   · 每次改提示词都要写迁移
//   · 用户误改会让 Agent 行为不可预期
// 所以内置技能跟版本走（builtin），用户只控制启停。
// 将来要支持自定义技能时，再加一张表存扩展技能即可，注册表按 id 合并。
//
// 【加一个新技能要改哪里】
// 只改这个文件的 _builtins 数组，加上模型侧的工具实现。
// 不动 Agent 循环、不动页面、不动数据库 schema。
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/skill.dart';

/// 内置技能 ID
class BuiltinSkill {
  const BuiltinSkill._();

  /// 术语纠错（沿用 A/B/C 三档规则，不编造）
  static const String termFix = 'term-fix';

  /// 生成结构化笔记（模板 + 档位）
  static const String summary = 'summary';

  /// 生成思维导图
  static const String mindmap = 'mindmap';

  /// 提取考点清单
  static const String examPoints = 'exam-points';

  /// 生成复习题
  static const String quiz = 'quiz';
}

class SkillRegistry {
  final SharedPreferences? _prefs;

  SkillRegistry({SharedPreferences? prefs}) : _prefs = prefs;

  static const String _prefsKey = 'enabled_skills';

  /// 内置技能定义。
  ///
  /// 每条 promptFragment 都是给模型看的编排说明，
  /// 会和 ClassroomAgent 的基础提示词拼在一起。
  static const List<Skill> builtins = [
    Skill(
      id: BuiltinSkill.termFix,
      name: '术语纠错',
      description: '查本节课术语表，按 A/B/C 三档修正误听术语，不编造',
      tools: ['run_correction_agent'],
      promptFragment: '''
## 术语纠错
文本较长（超过约 200 字）或含专业术语时，调用 run_correction_agent。
它会在纠错前先查本节课术语表，拿不准的只标待确认、绝不编造。
纠错要排在总结之前——总结吃的应该是纠错后的文本。
''',
    ),
    Skill(
      id: BuiltinSkill.summary,
      name: '生成笔记',
      description: '按模板与档位生成结构化课堂笔记',
      tools: ['summarize'],
      promptFragment: '''
## 生成笔记
调用 summarize 生成结构化笔记，level 按用户要求的档位填。
它会同时产出导图结构，但只有开启了「思维导图」技能时才会保留。
''',
    ),
    Skill(
      id: BuiltinSkill.mindmap,
      name: '思维导图',
      description: '生成 3-5 级详细导图，可直接在画布上浏览',
      tools: ['generate_mindmap'],
      promptFragment: '''
## 思维导图
调用 generate_mindmap 生成 3-5 级详细导图。
如果已经跑过 summarize，可以直接复用它的导图结构，不必重复生成。
''',
    ),
    Skill(
      id: BuiltinSkill.examPoints,
      name: '提取考点',
      description: '把本节课的考点、易错点整理成考前速查清单',
      tools: ['extract_exam_points'],
      promptFragment: '''
## 提取考点
调用 extract_exam_points 提取考点清单。
它只提取老师明确说了"会考""重点""注意"的内容，不推测。
用户明确提出"考点""重点""考什么"时优先做这件事。
''',
    ),
    Skill(
      id: BuiltinSkill.quiz,
      name: '生成复习题',
      description: '根据本节课内容出复习题，附参考答案与出处',
      tools: ['make_quiz'],
      promptFragment: '''
## 生成复习题
调用 make_quiz 出复习题。
题目只能考笔记里真的讲过的内容，答案必须能在原文找到依据。
用户提出"出题""复习题""自测"时使用。
''',
    ),
  ];

  /// 内置技能按 ID 查
  static Skill? byId(String id) {
    for (final s in builtins) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 全部技能（当前只有内置；将来可合并用户自定义）
  static List<Skill> all() => List.unmodifiable(builtins);

  /// 默认启用的技能 ID
  static List<String> get defaultEnabledIds =>
      builtins.where((s) => s.enabledByDefault).map((s) => s.id).toList();

  // ───────────────────── 启停状态 ─────────────────────

  /// 读取启用的技能 ID。没存过就返回默认值。
  Future<Set<String>> enabledIds() async {
    try {
      final prefs = _prefs ?? await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.trim().isEmpty) {
        return defaultEnabledIds.toSet();
      }
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final saved = decoded.map((e) => e.toString()).toSet();
        // 只保留仍然存在的技能（版本升级删掉的技能不该复活）
        final valid = builtins.map((s) => s.id).toSet();
        return saved.intersection(valid);
      }
    } catch (_) {
      // 读失败就用默认值，不让设置问题阻断处理流程
    }
    return defaultEnabledIds.toSet();
  }

  Future<void> saveEnabledIds(Set<String> ids) async {
    try {
      final prefs = _prefs ?? await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(ids.toList()));
    } catch (_) {}
  }

  Future<void> setEnabled(String skillId, bool enabled) async {
    final current = await enabledIds();
    if (enabled) {
      current.add(skillId);
    } else {
      current.remove(skillId);
    }
    await saveEnabledIds(current);
  }

  /// 组装本次运行的技能集合。
  ///
  /// [onlyIds] 非空时只用这些技能（供「这次只做某件事」的场景）；
  /// 否则按用户保存的启停状态 + 课程适用性筛选。
  Future<SkillSet> resolve({
    String courseName = '',
    Set<String>? onlyIds,
  }) async {
    final enabled = onlyIds ?? await enabledIds();
    final picked = builtins
        .where((s) => enabled.contains(s.id) && s.appliesTo(courseName))
        .toList();
    return SkillSet(picked);
  }

  /// 给设置页用：每个技能 + 是否启用 + 是否适用于某课程
  Future<List<({Skill skill, bool enabled})>> overview() async {
    final enabled = await enabledIds();
    return builtins
        .map((s) => (skill: s, enabled: enabled.contains(s.id)))
        .toList();
  }
}