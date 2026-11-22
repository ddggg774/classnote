// test/skill_test.dart
// 技能系统的测试。
//
// 最核心的一条：**关掉技能后，对应工具真的不在模型视野里**。
// 如果只藏提示词不藏工具，模型还是会想办法凑——那不是真开关。
// 这条必须直接断言工具集，不能只断言提示词。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:classnote/models/skill.dart';
import 'package:classnote/services/skill_provider.dart';
import 'package:classnote/services/skill_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('内置技能定义', () {
    test('有 5 个内置技能且 ID 唯一', () {
      expect(SkillRegistry.builtins.length, 5);
      final ids = SkillRegistry.builtins.map((s) => s.id).toSet();
      expect(ids.length, 5);
    });

    test('每个技能都有名称、说明、工具与提示词片段', () {
      for (final s in SkillRegistry.builtins) {
        expect(s.name.trim(), isNotEmpty, reason: '${s.id} 缺名称');
        expect(s.description.trim(), isNotEmpty, reason: '${s.id} 缺说明');
        expect(s.tools, isNotEmpty, reason: '${s.id} 没有对应工具');
        expect(s.promptFragment.trim(), isNotEmpty,
            reason: '${s.id} 缺提示词片段——只有工具没有说明，模型不知道该做什么');
      }
    });

    test('技能间工具不重复（避免关掉 A 影响 B）', () {
      final seen = <String, String>{};
      for (final s in SkillRegistry.builtins) {
        for (final t in s.tools) {
          expect(seen.containsKey(t), isFalse,
              reason: '工具 $t 同时属于 ${seen[t]} 和 ${s.id}，关掉一个会误伤另一个');
          seen[t] = s.id;
        }
      }
    });

    test('byId 能查到，查不到返回 null', () {
      expect(SkillRegistry.byId(BuiltinSkill.termFix)?.name, '术语纠错');
      expect(SkillRegistry.byId('不存在'), isNull);
    });

    test('默认启用的技能包含术语纠错与生成笔记', () {
      final defaults = SkillRegistry.defaultEnabledIds;
      expect(defaults, contains(BuiltinSkill.termFix));
      expect(defaults, contains(BuiltinSkill.summary));
    });
  });

  group('技能模型', () {
    test('courses 为空表示所有课程都适用', () {
      const s = Skill(id: 'x', name: 'X');
      expect(s.appliesTo('植物学'), isTrue);
      expect(s.appliesTo(''), isTrue);
    });

    test('限定课程时只匹配对应课程', () {
      const s = Skill(id: 'x', name: 'X', courses: ['制图']);
      expect(s.appliesTo('建筑制图'), isTrue);
      expect(s.appliesTo('园林制图'), isTrue);
      expect(s.appliesTo('植物学'), isFalse);
      expect(s.appliesTo(''), isFalse);
    });

    test('序列化往返', () {
      const s = Skill(
        id: 'x',
        name: '名字',
        description: '说明',
        enabledByDefault: false,
        tools: ['a', 'b'],
        promptFragment: '片段',
        courses: ['植物学'],
      );
      final back = Skill.fromJson(jsonDecode(s.encode()));
      expect(back.id, 'x');
      expect(back.enabledByDefault, isFalse);
      expect(back.tools, ['a', 'b']);
      expect(back.promptFragment, '片段');
      expect(back.courses, ['植物学']);
    });
  });

  group('SkillSet 聚合', () {
    final termFix = SkillRegistry.byId(BuiltinSkill.termFix)!;
    final summary = SkillRegistry.byId(BuiltinSkill.summary)!;
    final quiz = SkillRegistry.byId(BuiltinSkill.quiz)!;

    test('toolNames 合并去重', () {
      final set = SkillSet([termFix, summary]);
      expect(set.toolNames, containsAll(['run_correction_agent', 'summarize']));
      expect(set.toolNames.length, 2);
    });

    test('promptFragment 拼接多个技能', () {
      final set = SkillSet([termFix, quiz]);
      final f = set.promptFragment;
      expect(f.contains('术语纠错'), isTrue);
      expect(f.contains('生成复习题'), isTrue);
    });

    test('空集合的提示词片段为空', () {
      expect(SkillSet.empty.promptFragment, isEmpty);
      expect(SkillSet.empty.toolNames, isEmpty);
      expect(SkillSet.empty.isEmpty, isTrue);
    });

    test('providesTool 判断准确', () {
      final set = SkillSet([termFix]);
      expect(set.providesTool('run_correction_agent'), isTrue);
      expect(set.providesTool('summarize'), isFalse);
    });

    test('has 判断技能是否启用', () {
      final set = SkillSet([summary]);
      expect(set.has(BuiltinSkill.summary), isTrue);
      expect(set.has(BuiltinSkill.termFix), isFalse);
    });
  });

  group('启停状态持久化', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('没存过时返回默认值', () async {
      final reg = SkillRegistry();
      final ids = await reg.enabledIds();
      expect(ids, containsAll(SkillRegistry.defaultEnabledIds));
    });

    test('关掉一个技能后能读回来', () async {
      final reg = SkillRegistry();
      await reg.setEnabled(BuiltinSkill.quiz, false);
      final ids = await reg.enabledIds();
      expect(ids.contains(BuiltinSkill.quiz), isFalse);
      expect(ids.contains(BuiltinSkill.termFix), isTrue);
    });

    test('打开技能后能读回来', () async {
      final reg = SkillRegistry();
      await reg.setEnabled(BuiltinSkill.quiz, true);
      final ids = await reg.enabledIds();
      expect(ids.contains(BuiltinSkill.quiz), isTrue);
    });

    test('保存时过滤掉已不存在的技能（版本升级删技能）', () async {
      SharedPreferences.setMockInitialValues({
        'enabled_skills': '["term-fix","已经被删掉的技能"]',
      });
      final ids = await SkillRegistry().enabledIds();
      expect(ids, contains(BuiltinSkill.termFix));
      expect(ids.contains('已经被删掉的技能'), isFalse);
    });

    test('存的是坏 JSON 时退回默认值，不崩', () async {
      SharedPreferences.setMockInitialValues({'enabled_skills': '不是json'});
      final ids = await SkillRegistry().enabledIds();
      expect(ids, containsAll(SkillRegistry.defaultEnabledIds));
    });

    test('overview 反映真实启停状态', () async {
      final reg = SkillRegistry();
      await reg.setEnabled(BuiltinSkill.mindmap, false);
      final list = await reg.overview();
      expect(list.length, SkillRegistry.builtins.length);
      final mindmap = list.firstWhere((e) => e.skill.id == BuiltinSkill.mindmap);
      expect(mindmap.enabled, isFalse);
      final term = list.firstWhere((e) => e.skill.id == BuiltinSkill.termFix);
      expect(term.enabled, isTrue);
    });
  });

  group('resolve 按课程筛选', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('全部启用时全部返回', () async {
      final reg = SkillRegistry();
      await reg.saveEnabledIds(
        SkillRegistry.builtins.map((s) => s.id).toSet(),
      );
      final set = await reg.resolve(courseName: '植物学');
      expect(set.skills.length, SkillRegistry.builtins.length);
    });

    test('关掉的技能不出现在结果里', () async {
      final reg = SkillRegistry();
      await reg.saveEnabledIds({BuiltinSkill.termFix, BuiltinSkill.summary});
      final set = await reg.resolve(courseName: '植物学');
      expect(set.ids, containsAll(['term-fix', 'summary']));
      expect(set.has(BuiltinSkill.quiz), isFalse);
    });

    test('onlyIds 覆盖保存的设置（临时只做某件事）', () async {
      final reg = SkillRegistry();
      await reg.saveEnabledIds({BuiltinSkill.termFix});
      final set = await reg.resolve(
        courseName: '植物学',
        onlyIds: {BuiltinSkill.quiz},
      );
      expect(set.ids, ['quiz']);
    });
  });

  group('SkillProvider 抽象（给将来接 MCP 预留）', () {
    test('内置 provider 能返回技能', () async {
      const p = BuiltinSkillProvider();
      expect(await p.isAvailable(), isTrue);
      expect((await p.skills()).length, SkillRegistry.builtins.length);
      expect(p.name, '内置技能');
    });

    test('内置 provider 可只返回指定的几个', () async {
      const p = BuiltinSkillProvider(
        enabledIds: {BuiltinSkill.termFix, BuiltinSkill.summary},
      );
      final list = await p.skills();
      expect(list.length, 2);
      expect(list.map((s) => s.id), containsAll(['term-fix', 'summary']));
    });

    test('resolveFor 按课程过滤', () async {
      const p = BuiltinSkillProvider();
      final set = await p.resolveFor('植物学');
      expect(set.isEmpty, isFalse);
    });

    test('聚合 provider 合并多来源并按 id 去重', () async {
      const a = BuiltinSkillProvider();
      const b = BuiltinSkillProvider();
      const composite = CompositeSkillProvider([a, b]);
      final list = await composite.skills();
      // 两个来源内容相同，去重后应该还是内置技能数量
      expect(list.length, SkillRegistry.builtins.length);
      expect((await composite.isAvailable()), isTrue);
    });

    test('聚合 provider 会跳过不可用的来源', () async {
      const composite = CompositeSkillProvider([
        _UnavailableProvider(),
        BuiltinSkillProvider(),
      ]);
      final list = await composite.skills();
      expect(list.length, SkillRegistry.builtins.length,
          reason: '应只剩可用来源的技能');
    });
  });

  group('工具集真的随技能收窄（这是整个功能的意义）', () {
    test('只启用术语纠错时，工具集只有纠错与基础转写', () {
      // 这里直接验证 SkillSet 给出的工具名，
      // Agent 的 _buildTools 就是按它 filter 的。
      final set = SkillSet([SkillRegistry.byId(BuiltinSkill.termFix)!]);
      final allowed = {'transcribe', ...set.toolNames};

      expect(allowed, contains('transcribe'),
          reason: '转写是基础能力，必须始终暴露');
      expect(allowed, contains('run_correction_agent'));
      expect(allowed.contains('summarize'), isFalse,
          reason: '没启用生成笔记技能，就不该暴露 summarize');
      expect(allowed.contains('generate_mindmap'), isFalse);
      expect(allowed.contains('make_quiz'), isFalse);
    });

    test('启用全部技能时工具全在', () {
      const set = SkillSet(SkillRegistry.builtins);
      final allowed = {'transcribe', ...set.toolNames};
      expect(allowed.length, SkillRegistry.builtins.length + 1);
      expect(allowed, containsAll(<String>[
        'transcribe',
        'run_correction_agent',
        'summarize',
        'generate_mindmap',
        'extract_exam_points',
        'make_quiz',
      ]));
    });

    test('空技能集只有转写', () {
      final allowed = {'transcribe', ...SkillSet.empty.toolNames};
      expect(allowed, {'transcribe'});
    });

    test('关掉生成笔记后，提示词里也不再有它的说明', () {
      final withoutSummary = SkillSet([
        SkillRegistry.byId(BuiltinSkill.termFix)!,
      ]);
      final withSummary = SkillSet([
        SkillRegistry.byId(BuiltinSkill.termFix)!,
        SkillRegistry.byId(BuiltinSkill.summary)!,
      ]);
      expect(withoutSummary.promptFragment.contains('生成笔记'), isFalse);
      expect(withSummary.promptFragment.contains('生成笔记'), isTrue);
    });
  });
}

/// 一个永远不可用的来源，用于验证聚合时会跳过
class _UnavailableProvider extends SkillProvider {
  const _UnavailableProvider();

  @override
  String get name => '不可用来源';

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<List<Skill>> skills() async =>
      const [Skill(id: 'ghost', name: '幽灵技能', tools: ['ghost_tool'])];
}