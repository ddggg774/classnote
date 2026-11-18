// lib/pages/record_page.dart
// 记录页：支持两种把内容变成文字的方式——
// ① 点「录音」说话，录完自动上传硅基流动识别，文字追加到框里（云端方案，不挑手机）；
// ② 直接用手机输入法的麦克风 / 手动打字 / 粘贴，文字进框。
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/note.dart';
import '../services/cloud_asr_service.dart';
import '../services/db_service.dart';

class RecordPage extends StatefulWidget {
  const RecordPage({super.key});

  @override
  State<RecordPage> createState() => _RecordPageState();
}

class _RecordPageState extends State<RecordPage> {
  final DbService _db = DbService();
  final CloudAsrService _asr = CloudAsrService();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _transcriptController = TextEditingController();

  final DateTime _startTime = DateTime.now();

  bool _recognizing = false; // 正在上传识别

  /// 每段识别完成后，把文字追加到文本框（保持光标在末尾）
  void _appendText(String text) {
    final existing = _transcriptController.text;
    _transcriptController.text = existing.isEmpty ? text : '$existing\n$text';
    _transcriptController.selection = TextSelection.collapsed(offset: _transcriptController.text.length);
    setState(() {});
  }

  /// 录音按钮：点一下开始（一直录、自动分段），再点一下停止并等最后一段识别完
  Future<void> _toggleRecord() async {
    if (_recognizing) return;

    if (_asr.isRecording) {
      // 停止录音：内部会等所有分段识别完
      if (mounted) setState(() => _recognizing = true);
      try {
        await _asr.stopRecording();
        _showSnack('转写完成，可检查文字后保存');
      } catch (e) {
        _showSnack('处理失败：$e');
      } finally {
        if (mounted) setState(() => _recognizing = false);
      }
      return;
    }

    // 开始录音前先检查权限
    final hasMic = await _asr.hasPermission();
    if (!hasMic) {
      _showSnack('请先允许麦克风权限：手机设置 → 应用 → 课堂笔记 → 权限');
      return;
    }
    try {
      await _asr.startRecording(
        onText: _appendText,
        onError: (msg) => _showSnack(msg),
      );
      if (mounted) setState(() {});
    } catch (e) {
      _showSnack('无法开始录音：$e');
    }
  }

  /// 完成并记录：保存笔记后返回首页
  Future<void> _finishAndSave() async {
    final text = _transcriptController.text.trim();
    if (text.isEmpty) {
      _showSnack('还没有内容，先录一段或输入文字吧');
      return;
    }

    final title = _titleController.text.trim().isEmpty
        ? '未命名课堂'
        : _titleController.text.trim();
    final duration = DateTime.now().difference(_startTime).inSeconds;

    final note = Note(
      id: const Uuid().v4(),
      title: title,
      transcript: text,
      createdAt: DateTime.now(),
      duration: duration,
    );
    await _db.insert(note);
    if (mounted) Navigator.of(context).pop();
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _asr.dispose();
    _titleController.dispose();
    _transcriptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final recording = _asr.isRecording;

    return Scaffold(
      appBar: AppBar(title: const Text('新建课堂记录')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 课程名输入
              TextField(
                controller: _titleController,
                decoration: InputDecoration(
                  labelText: '课程名称（可留空）',
                  hintText: '例如：高等数学 第三讲',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  prefixIcon: const Icon(Icons.edit),
                ),
              ),
              const SizedBox(height: 12),

              // 操作引导
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.indigo.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.indigo.shade100),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, color: Colors.indigo.shade700, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '点下方红色「开始录音」后一直说就行，App 会自动分段转文字、接着往下写，录多久都可以。'
                        '说完点「停止」。也可以直接用输入法的麦克风 🎤 或手动输入。（需联网）',
                        style: TextStyle(
                          color: Colors.indigo.shade900,
                          fontSize: 12.5,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // 大号文字输入框
              Expanded(
                child: TextField(
                  controller: _transcriptController,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(fontSize: 16, height: 1.6),
                  decoration: InputDecoration(
                    hintText: '录音识别的文字会自动出现在这里；也可以直接打字或粘贴…',
                    filled: true,
                    fillColor: Colors.grey.shade100,
                    contentPadding: const EdgeInsets.all(14),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(height: 6),

              // 字数 + 清空
              Row(
                children: [
                  Text(
                    '${_transcriptController.text.length} 字',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _transcriptController.text.isEmpty
                        ? null
                        : () {
                            _transcriptController.clear();
                            setState(() {});
                          },
                    icon: const Icon(Icons.clear_all, size: 18),
                    label: const Text('清空'),
                  ),
                ],
              ),
              const SizedBox(height: 6),

              // 录音按钮（开始/停止）
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: _recognizing ? null : _toggleRecord,
                  icon: _recognizing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : Icon(recording ? Icons.stop : Icons.mic),
                  label: Text(
                    _recognizing
                        ? '正在转写最后一段…'
                        : recording
                            ? '停止录音'
                            : '开始录音（一直录，自动转写）',
                    style: const TextStyle(fontSize: 18),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: recording ? Colors.red : Colors.indigo,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // 完成并记录
              SizedBox(
                width: double.infinity,
                height: 50,
                child: OutlinedButton.icon(
                  onPressed: _recognizing || _transcriptController.text.trim().isEmpty
                      ? null
                      : _finishAndSave,
                  icon: const Icon(Icons.check),
                  label: const Text('完成并记录'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
