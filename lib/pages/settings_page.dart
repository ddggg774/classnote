// lib/pages/settings_page.dart
// 设置页：填写 DeepSeek Key（用于总结）和硅基流动 Key（用于语音识别）。
// 都保存在本地，改 Key 无需重新打包。
import 'package:flutter/material.dart';

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

  Future<void> _save() async {
    final dsKey = _deepSeekController.text.trim();
    final asrKey = _asrController.text.trim();
    if (dsKey.isEmpty && asrKey.isEmpty) {
      _showSnack('请至少填写一个 Key');
      return;
    }
    await _settings.saveApiKey(dsKey);
    await _settings.saveAsrKey(asrKey);
    if (mounted) _showSnack('已保存');
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
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
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
                  helper: '用于把课堂文字总结成要点和思维导图。申请：https://platform.deepseek.com',
                ),
                const SizedBox(height: 24),

                const Text(
                  '两个 Key 都只保存在本机，不会上传。语音识别必须联网使用。',
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
