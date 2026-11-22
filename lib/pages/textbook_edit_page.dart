// lib/pages/textbook_edit_page.dart
// 新建 / 编辑一本教材的元数据。
//
// 只填书名、版次、编者、出版社这些「书上印着的字」。
// 章节目录不在这里录——目录有独立的页面（textbook_toc_page.dart），
// 因为那一步要粘贴、要逐条加，混在一个表单里会很难用。

import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import '../config.dart';
import '../models/textbook.dart';
import '../services/textbook_service.dart';

class TextbookEditPage extends StatefulWidget {
  const TextbookEditPage({super.key, this.textbook});

  /// 传了就表示编辑；为空表示新建
  final Textbook? textbook;

  @override
  State<TextbookEditPage> createState() => _TextbookEditPageState();
}

class _TextbookEditPageState extends State<TextbookEditPage> {
  final TextbookService _service = TextbookService();

  late final TextEditingController _titleCtrl;
  late final TextEditingController _editionCtrl;
  late final TextEditingController _authorCtrl;
  late final TextEditingController _publisherCtrl;
  late final TextEditingController _yearCtrl;
  late final TextEditingController _isbnCtrl;

  String _course = '';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final t = widget.textbook;
    _titleCtrl = TextEditingController(text: t?.title ?? '');
    _editionCtrl = TextEditingController(text: t?.edition ?? '');
    _authorCtrl = TextEditingController(text: t?.author ?? '');
    _publisherCtrl = TextEditingController(text: t?.publisher ?? '');
    _yearCtrl = TextEditingController(text: t?.year ?? '');
    _isbnCtrl = TextEditingController(text: t?.isbn ?? '');
    _course = t?.course ?? '';
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _editionCtrl.dispose();
    _authorCtrl.dispose();
    _publisherCtrl.dispose();
    _yearCtrl.dispose();
    _isbnCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    if (_course.trim().isEmpty) {
      _showSnack('先选课程：教材要靠它和笔记对上');
      return;
    }
    if (title.isEmpty) {
      _showSnack('书名不能为空');
      return;
    }

    setState(() => _saving = true);
    try {
      final existing = widget.textbook;
      final textbook = Textbook(
        id: existing?.id ?? const Uuid().v4(),
        course: _course.trim(),
        title: title,
        edition: _editionCtrl.text.trim(),
        author: _authorCtrl.text.trim(),
        publisher: _publisherCtrl.text.trim(),
        year: _yearCtrl.text.trim(),
        isbn: _isbnCtrl.text.trim(),
        tocSource: existing?.tocSource ?? Textbook.tocNone,
        tocUpdatedAt: existing?.tocUpdatedAt,
        sortOrder: existing?.sortOrder ?? 0,
      );
      await _service.save(textbook);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) _showSnack('保存失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickCustomCourse() async {
    final ctrl = TextEditingController(text: _course);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('课程名'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '例如：植物学',
            helperText: '要和录音页选的课程名一致，否则带不出这本教材',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    // 对话框关闭动画期间 TextField 仍引用 controller，延后释放
    WidgetsBinding.instance.addPostFrameCallback((_) => ctrl.dispose());
    if (result == null || !mounted) return;
    setState(() => _course = result);
  }

  @override
  Widget build(BuildContext context) {
    final preset = AppConfig.textbooks.map((t) => t.course).toList();
    final isPreset = preset.contains(_course);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.textbook == null ? '新建教材' : '编辑教材'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('课程',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final c in preset)
                ChoiceChip(
                  label: Text(c, style: const TextStyle(fontSize: 12)),
                  selected: _course == c,
                  visualDensity: VisualDensity.compact,
                  onSelected: (v) => setState(() => _course = v ? c : ''),
                ),
              if (_course.isNotEmpty && !isPreset)
                InputChip(
                  label: Text(_course, style: const TextStyle(fontSize: 12)),
                  selected: true,
                  onDeleted: () => setState(() => _course = ''),
                  visualDensity: VisualDensity.compact,
                ),
              ActionChip(
                avatar: const Icon(Icons.add, size: 14),
                label: const Text('自定义', style: TextStyle(fontSize: 12)),
                visualDensity: VisualDensity.compact,
                onPressed: _pickCustomCourse,
              ),
            ],
          ),
          const SizedBox(height: 20),
          _field(_titleCtrl, '书名', '例如：植物学'),
          const SizedBox(height: 12),
          _field(_editionCtrl, '版次', '例如：第三版'),
          const SizedBox(height: 12),
          _field(_authorCtrl, '编者', '例如：方炎明 主编'),
          const SizedBox(height: 12),
          _field(_publisherCtrl, '出版社', '例如：中国林业出版社'),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _field(_yearCtrl, '出版年（可选）', '2018')),
              const SizedBox(width: 10),
              Expanded(child: _field(_isbnCtrl, 'ISBN（可选）', '978-7-...')),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            '书名、版次、编者、出版社都会进提示词——模型知道「方炎明《植物学》第三版」'
            '这一章通常讲什么，纠错时更不容易听错专业词。',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600, height: 1.5),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: const Text('保存'),
            ),
          ),
          if (widget.textbook != null) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 46,
              child: OutlinedButton.icon(
                onPressed: _saving ? null : _confirmDelete,
                icon: const Icon(Icons.delete_outline),
                label: const Text('删除这本教材'),
                style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String label, String hint) {
    return TextField(
      controller: ctrl,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Future<void> _confirmDelete() async {
    final t = widget.textbook;
    if (t == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除教材'),
        content: Text('删除「${t.displayTitle}」及其已录入的章节目录？\n'
            '已经记下的笔记不受影响，它们只是不再关联这本教材。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _service.delete(t.id);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}