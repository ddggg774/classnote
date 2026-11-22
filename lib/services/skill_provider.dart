// lib/services/skill_provider.dart
// 技能来源的抽象。
//
// 【为什么现在就要这层抽象】
// 当前技能全部来自代码里的内置定义（SkillRegistry）。
// 将来如果要接 MCP server 或者用户自定义技能，不应该改 Agent 和页面，
// 只应该加一个 SkillProvider 实现。所以这层现在虽然只有一个实现，
// 但它把「技能从哪来」和「技能怎么用」分开了。
//
// 【为什么不直接做 MCP 客户端】
// 真 MCP 客户端要实现 SSE/HTTP 传输 + JSON-RPC 2.0 + 能力协商 + 工具调用协议，
// 在移动 App 里做完整实现工作量大，而且用户的 MCP server 场景还不明确。
// 先把内部技能系统做好，MCP 留成接口——真要接时实现 MCP 客户端只是个适配器。
import '../models/skill.dart';
import 'skill_registry.dart';

/// 技能来源
abstract class SkillProvider {
  const SkillProvider();

  /// 这个来源叫什么（设置页展示用）
  String get name;

  /// 是否可用（比如 MCP provider 在没连上 server 时返回 false）
  Future<bool> isAvailable();

  /// 取这个来源能提供的全部技能
  Future<List<Skill>> skills();

  /// 取某个课程下适用的技能
  Future<SkillSet> resolveFor(String courseName) async {
    final all = await skills();
    final picked = all.where((s) => s.appliesTo(courseName)).toList();
    return SkillSet(picked);
  }
}

/// 内置技能来源（包一层 SkillRegistry，让内置技能也走统一接口）
class BuiltinSkillProvider extends SkillProvider {
  final Set<String> enabledIds;

  const BuiltinSkillProvider({this.enabledIds = const {}});

  @override
  String get name => '内置技能';

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<List<Skill>> skills() async {
    // 没指定启用集合时返回全部内置技能
    if (enabledIds.isEmpty) return List.of(SkillRegistry.builtins);
    return SkillRegistry.builtins
        .where((s) => enabledIds.contains(s.id))
        .toList();
  }
}

/// 聚合多个来源。
///
/// 这是将来接 MCP 的挂载点：把 MCP provider 加进 providers 列表即可，
/// Agent 与页面完全不用改。
class CompositeSkillProvider extends SkillProvider {
  final List<SkillProvider> providers;

  const CompositeSkillProvider(this.providers);

  @override
  String get name => '合并技能源';

  @override
  Future<bool> isAvailable() async {
    for (final p in providers) {
      if (await p.isAvailable()) return true;
    }
    return false;
  }

  @override
  Future<List<Skill>> skills() async {
    final out = <Skill>[];
    for (final p in providers) {
      if (!await p.isAvailable()) continue;
      out.addAll(await p.skills());
    }
    // 同 id 去重：先加进来的（内置）优先
    final seen = <String>{};
    return out.where((s) => seen.add(s.id)).toList();
  }

  @override
  Future<SkillSet> resolveFor(String courseName) async {
    final all = await skills();
    return SkillSet(all.where((s) => s.appliesTo(courseName)).toList());
  }
}
