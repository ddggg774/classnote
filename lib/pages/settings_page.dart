// lib/pages/settings_page.dart
// 设置页：填写 DeepSeek Key（用于总结）和硅基流动 Key（用于语音识别）。
// 都保存在本地，改 Key 无需重新打包。
import 'package:material_ui/material_ui.dart';

import '../config.dart';
import '../services/audio_capture_profile.dart';
import '../services/settings_service.dart';
import '../services/skill_registry.dart';
import 'disclaimer_page.dart';
import 'textbook_list_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final SettingsService _settings = SettingsService();
  final TextEditingController _deepSeekController = TextEditingController();
  final TextEditingController _asrController = TextEditingController();
  final TextEditingController _glossaryController = TextEditingController();
  bool _obscureDeepSeek = true;
  bool _obscureAsr = true;
  bool _loading = true;
  /// 当前选用的识别模型
  String _asrModel = AppConfig.asrModel;
  /// 转写后是否自动 AI 纠错
  bool _autoCorrect = false;
  CaptureProfile _captureProfile = CaptureProfile.normal;

  /// 技能启停（id → 是否启用）
  Map<String, bool> _skillEnabled = {};
  bool _skillsLoaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final dsKey = await _settings.getApiKey();
    final asrKey = await _settings.getAsrKey();
    final model = await _settings.getAsrModel();
    final glossary = await _settings.getGlossary();
    final auto = await _settings.getAutoCorrect();
    final profileCode = await _settings.getCaptureProfile();
    final profile = CaptureProfile.fromCode(profileCode);
    final skills = await SkillRegistry().overview();
    if (mounted) {
      setState(() {
        _deepSeekController.text = dsKey;
        _asrController.text = asrKey;
        _glossaryController.text = glossary;
        _asrModel = model;
        _autoCorrect = auto;
        _captureProfile = profile;
        _skillEnabled = {for (final s in skills) s.skill.id: s.enabled};
        _skillsLoaded = true;
        _loading = false;
      });
    }
  }

  /// 保存 Key。
  ///
  /// 旧版无条件把两个输入框的值写回去，用户在某个框里手滑清空就会**静默擦掉已有 Key**，
  /// 而且下次录音/总结时才发现。现在改成：
  ///   - 空框 = 不修改（保留原 Key）；
  ///   - 想清空必须点右边「清除」，并且过一次二次确认；
  ///   - 保存前做一次轻量格式校验，Typo 不用等到 5 分钟后上传才暴露。
  Future<void> _save() async {
    final dsKey = _deepSeekController.text.trim();
    final asrKey = _asrController.text.trim();

    if (dsKey.isEmpty && asrKey.isEmpty) {
      _showSnack('两个 Key 都是空的，没有可保存的内容');
      return;
    }

    final bad = <String>[];
    if (dsKey.isNotEmpty && !_looksLikeKey(dsKey)) bad.add('DeepSeek Key');
    if (asrKey.isNotEmpty && !_looksLikeKey(asrKey)) bad.add('硅基流动 Key');
    if (bad.isNotEmpty) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Key 格式看起来不对'),
          content: Text('${bad.join('、')} 不像常见的 sk- 开头格式，'
              '继续保存可能仍然无法使用。确定要保存吗？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('回去检查')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('仍然保存')),
          ],
        ),
      );
      if (go != true) return;
    }

    if (dsKey.isNotEmpty) await _settings.saveApiKey(dsKey);
    if (asrKey.isNotEmpty) await _settings.saveAsrKey(asrKey);
    // 模型选择、术语表、自动纠错开关每次保存都写（它们不是"空即保留"的语义）
    await _settings.saveAsrModel(_asrModel);
    await _settings.saveGlossary(_glossaryController.text);
    await _settings.saveAutoCorrect(_autoCorrect);
    await _settings.saveCaptureProfile(_captureProfile.name);
    if (_skillsLoaded) {
      await SkillRegistry().saveEnabledIds(
        _skillEnabled.entries
            .where((e) => e.value)
            .map((e) => e.key)
            .toSet(),
      );
    }

    if (!mounted) return;
    final kept = <String>[
      if (dsKey.isEmpty) 'DeepSeek Key 保持原样',
      if (asrKey.isEmpty) '硅基流动 Key 保持原样',
    ];
    _showSnack(kept.isEmpty ? '已保存' : '已保存（${kept.join('，')}）');
  }

  /// 轻量格式校验：常见 Key 都是 sk- 开头、长度 20 以上。
  /// 这里只做提示不做拦截，避免把用了别的格式的用户挡在外面。
  bool _looksLikeKey(String key) =>
      key.length >= 20 && key.startsWith('sk-');

  /// 清空某个 Key（带二次确认，避免手滑）
  Future<void> _clearKey({
    required String label,
    required TextEditingController controller,
    required Future<void> Function() clear,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('清除$label'),
        content: const Text('清除后需要重新填写才能继续使用，确定吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清除')),
        ],
      ),
    );
    if (ok != true) return;
    await clear();
    controller.clear();
    if (mounted) {
      setState(() {});
      _showSnack('已清除$label');
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Widget _buildKeyField({
    required String label,
    required String hint,
    required TextEditingController controller,
    required bool obscure,
    required VoidCallback onToggleObscure,
    required String helper,
    VoidCallback? onClear,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            if (onClear != null && controller.text.isNotEmpty)
              TextButton(
                onPressed: onClear,
                child: const Text('清除', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          obscureText: obscure,
          decoration: InputDecoration(
            hintText: hint,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            suffixIcon: IconButton(
              icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
              onPressed: onToggleObscure,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(helper, style: const TextStyle(color: Colors.grey, fontSize: 12.5, height: 1.5)),
      ],
    );
  }

  @override
  void dispose() {
    _deepSeekController.dispose();
    _asrController.dispose();
    _glossaryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // 语音识别 Key
                _buildKeyField(
                  label: '① 硅基流动 API Key（语音转文字用）',
                  hint: 'sk-xxxxxxxxxxxxxxxx',
                  controller: _asrController,
                  obscure: _obscureAsr,
                  onToggleObscure: () => setState(() => _obscureAsr = !_obscureAsr),
                  onClear: () => _clearKey(
                    label: '硅基流动 Key',
                    controller: _asrController,
                    clear: () async => _settings.saveAsrKey(''),
                  ),
                  helper: '把录音转成文字，SenseVoiceSmall 模型永久免费。\n'
                      '手机申请：https://cloud.siliconflow.cn 注册→实名(支付宝刷脸)→API密钥→创建，复制粘贴到这里。',
                ),
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 24),

                // 识别模型选择：同一接口下可切换，用来对比哪个更准
                const Text('识别模型',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                (() {
                  final options = AppConfig.asrModelOptions
                      .map((m) => RadioListTile<String>(
                            value: m.value,
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(m.label,
                                style: const TextStyle(fontSize: 14)),
                            subtitle: Text(m.note,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade600)),
                          ))
                      .toList();
                  // Flutter 3.32 起 RadioListTile 的 groupValue/onChanged 已废弃，
                  // 统一由 RadioGroup 祖先管理选中值与回调。
                  return RadioGroup<String>(
                    groupValue: _asrModel,
                    onChanged: (v) =>
                        setState(() => _asrModel = v ?? AppConfig.asrModel),
                    child: Column(children: options),
                  );
                })(),
                Text(
                  '两个模型走同一个接口、同一个 Key。觉得识别不准时换另一个录一段对比。',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 24),

                // 总结 Key
                _buildKeyField(
                  label: '② DeepSeek API Key（AI 总结用）',
                  hint: 'sk-xxxxxxxxxxxxxxxx',
                  controller: _deepSeekController,
                  obscure: _obscureDeepSeek,
                  onToggleObscure: () => setState(() => _obscureDeepSeek = !_obscureDeepSeek),
                  onClear: () => _clearKey(
                    label: 'DeepSeek Key',
                    controller: _deepSeekController,
                    clear: () async => _settings.saveApiKey(''),
                  ),
                  helper: '用于把课堂文字总结成要点和思维导图。申请：https://platform.deepseek.com',
                ),
                const SizedBox(height: 24),

                // 术语表：给 AI 纠错当参考词典
                const Text('术语表（可选）',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                TextField(
                  controller: _glossaryController,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: '每行一个，例如：洛必达法则 / ε-δ 定义 / 傅里叶变换',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '填写本节课会用到的专业名词、人名，纠错时 AI 会优先按这些写法纠正。'
                  '注意：硅基流动的识别接口本身不支持热词，这里只影响「转写后的纠错」。',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  value: _autoCorrect,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('停止录音后自动 AI 纠错',
                      style: TextStyle(fontSize: 14)),
                  subtitle: Text(
                    '会多一次 DeepSeek 调用、收尾多等几秒；也可以之后在笔记里手动纠错。',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  onChanged: (v) => setState(() => _autoCorrect = v),
                ),
                const SizedBox(height: 16),

                // ── 拾音档位 ──
                Row(
                  children: [
                    const Text('远场拾音',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 6),
                    Text('当前：${_captureProfile.activeEffects}',
                        style: TextStyle(
                            fontSize: 11.5, color: Colors.grey.shade600)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '降噪 / 自动增益 / 回声消除由系统音频框架在录音时处理，'
                  '不额外耗电、不增加安装包体积。坐后排录课建议选「大教室/后排」。',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 4),
                RadioGroup<CaptureProfile>(
                  groupValue: _captureProfile,
                  onChanged: (v) {
                    if (v != null) setState(() => _captureProfile = v);
                  },
                  child: Column(
                    children: CaptureProfile.values
                        .map((p) => RadioListTile<CaptureProfile>(
                              value: p,
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(p.label,
                                  style: const TextStyle(fontSize: 13.5)),
                              subtitle: Text(p.description,
                                  style: TextStyle(
                                      fontSize: 11.5,
                                      color: Colors.grey.shade600)),
                            ))
                        .toList(),
                  ),
                ),
                const SizedBox(height: 20),

                // ── 技能开关 ──
                Row(
                  children: [
                    const Text('技能',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 6),
                    Text(
                      '${_skillEnabled.values.where((v) => v).length} / ${_skillEnabled.length} 已启用',
                      style: TextStyle(
                          fontSize: 11.5, color: Colors.grey.shade600),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '关掉的技能不会出现在「一键处理」里——连对应工具都不暴露给模型，'
                  '不是只藏起来不提示。',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 4),
                if (_skillsLoaded)
                  ...SkillRegistry.builtins.map((skill) => SwitchListTile(
                        value: _skillEnabled[skill.id] ?? false,
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(skill.name,
                            style: const TextStyle(fontSize: 13.5)),
                        subtitle: Text(skill.description,
                            style: TextStyle(
                                fontSize: 11.5,
                                color: Colors.grey.shade600)),
                        onChanged: (v) => setState(
                            () => _skillEnabled[skill.id] = v),
                      )),
                const SizedBox(height: 16),

                // 教材库：录音前定位章节的数据来源
                const Divider(),
                const SizedBox(height: 8),
                const Text('教材管理',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(
                  '录入教材目录后，录音前可以选到「第五章 · 第二节」这种粒度，'
                  '术语表、纠错和总结都会用上它。',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.menu_book_outlined),
                  title: const Text('教材与章节目录',
                      style: TextStyle(fontSize: 13.5)),
                  subtitle: Text('程序不会自动生成章节号，只认你录入的目录',
                      style: TextStyle(
                          fontSize: 11.5, color: Colors.grey.shade600)),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const TextbookListPage()),
                  ),
                ),
                const SizedBox(height: 16),

                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.gavel_outlined),
                  title: const Text('免责声明',
                      style: TextStyle(fontSize: 13.5)),
                  subtitle: Text(
                    '录音合规、AI 内容边界、第三方服务与责任限制'
                    '（版本 ${Disclaimer.version}）',
                    style: TextStyle(
                        fontSize: 11.5, color: Colors.grey.shade600),
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => DisclaimerPage(
                        readOnly: true,
                        onAccepted: () {},
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                const Text(
                  '两个 Key 都只保存在本机，不会上传。语音识别必须联网使用。\n'
                  '提示：输入框留空保存 = 保留原有 Key；想清空请点右上角「清除」。',
                  style: TextStyle(color: Colors.grey, fontSize: 12.5, height: 1.5),
                ),
                const SizedBox(height: 16),

                SizedBox(
                  height: 50,
                  child: ElevatedButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save),
                    label: const Text('保存'),
                  ),
                ),
              ],
            ),
    );
  }
}
