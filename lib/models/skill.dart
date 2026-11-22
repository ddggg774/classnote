// lib/models/skill.dart
// 技能：把「一键处理」的固定四步变成可插拔的任务项。
//
// 【为什么技能不只是「一组工具」】
// 如果技能只决定暴露哪些工具，那「关掉总结」只是让模型看不到 summarize，
// 但系统提示词里还写着"要生成总结"——模型会困惑，或者用别的工具凑。
// 所以一个技能必须是两件事绑在一起：
//   ① promptFragment：告诉模型"这件事要做、怎么做"
//   ② tools：把对应的工具暴露出来
// 两者同时生效/同时消失，关掉才是真的关掉。
//
// 【为什么技能不带「顺序」】
// 顺序交给编排 Agent 自己判断（这是整个 Agent 化的意义）。
// 硬编码顺序等于又回到 if/else 流水线。
import 'dart:convert';

class Skill {
  final String id;
  final String name;

  /// 一句话说明，显示在设置页
  final String description;

  /// 默认是否启用
  final bool enabledByDefault;

  /// 这个技能需要的工具名。关掉技能时这些工具不会暴露给模型。
  final List<String> tools;

  /// 拼进 systemPrompt 的说明。空表示只暴露工具不额外提示。
  final String promptFragment;

  /// 限定课程（空 = 所有课程都适用）。
  /// 比如「制图规范检查」只对制图课有意义。
  final List<String> courses;

  const Skill({
    required this.id,
    required this.name,
    this.description = '',
    this.enabledByDefault = true,
    this.tools = const [],
    this.promptFragment = '',
    this.courses = const [],
  });

  /// 是否适用于某课程
  bool appliesTo(String courseName) {
    if (courses.isEmpty) return true;
    final c = courseName.trim();
    if (c.isEmpty) return false;
    for (final course in courses) {
      if (c.contains(course) || course.contains(c)) return true;
    }
    return false;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'enabledByDefault': enabledByDefault,
        'tools': tools,
        'promptFragment': promptFragment,
        'courses': courses,
      };

  factory Skill.fromJson(Map<String, dynamic> json) => Skill(
        id: (json['id'] as String?)?.trim() ?? '',
        name: (json['name'] as String?)?.trim() ?? '',
        description: json['description'] as String? ?? '',
        enabledByDefault: json['enabledByDefault'] as bool? ?? true,
        tools: ((json['tools'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        promptFragment: json['promptFragment'] as String? ?? '',
        courses: ((json['courses'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );

  String encode() => jsonEncode(toJson());
}

/// 一次运行实际启用的技能集合
class SkillSet {
  final List<Skill> skills;

  const SkillSet(this.skills);

  static const SkillSet empty = SkillSet([]);

  bool get isEmpty => skills.isEmpty;

  List<String> get ids => skills.map((s) => s.id).toList();

  /// 需要暴露给模型的全部工具名（去重）
  List<String> get toolNames {
    final out = <String>{};
    for (final s in skills) {
      out.addAll(s.tools);
    }
    return out.toList();
  }

  /// 拼接所有技能的提示词片段
  String get promptFragment {
    final fragments = skills
        .map((s) => s.promptFragment.trim())
        .where((f) => f.isNotEmpty)
        .toList();
    if (fragments.isEmpty) return '';
    return fragments.join('\n\n');
  }

  bool has(String skillId) => skills.any((s) => s.id == skillId);

  bool providesTool(String toolName) =>
      skills.any((s) => s.tools.contains(toolName));
}