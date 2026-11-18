// lib/pages/settings_page.dart
// 设置页：填写 DeepSeek Key（用于总结）和硅基流动 Key（用于语音识别）。
// 都保存在本地，改 Key 无需重新打包。
import 'package:material_ui/material_ui.dart';

import '../services/settings_service.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final SettingsService _settings = SettingsService();
  final TextEditingController _deepSeekController = TextEditingController();
  final TextEditingController _asrController = TextEditingController();
  bool _obscureDeepSeek = true;
  bool _obscureAsr = true;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final dsKey = await _settings.getApiKey();
    final asrKey = await _settings.getAsrKey();
    if (mounted) {
      setState(() {
        _deepSeekController.text = dsKey;
        _asrController.text = asrKey;
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
