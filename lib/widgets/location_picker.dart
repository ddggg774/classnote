// lib/widgets/location_picker.dart
// 「这节课讲到哪」选择器：课程 → 教材 → 章 → 节。
//
// 录音页和笔记详情页共用同一个面板：
//   · 录音前定位（RecordPage）
//   · 事后修改位置（NoteDetailPage）
// 所以它必须能接受一个「已经选好的位置」并原样回填。
//
// 【为什么不做成 ExpansionTile】
// ExpansionTile 点一下既展开又选中，用户想「只看节不选章」时行为不可预测。
// 这里把「选中」和「展开」拆开：点章行 = 选中并展开，点节行 = 选中并立即返回。

import 'package:material_ui/material_ui.dart';

import '../models/course_location.dart';
import '../models/textbook.dart';
import '../services/textbook_service.dart';

/// 打开位置选择面板。返回 null 表示用户取消（保持原选择不变）。
Future<CourseLocation?> showLocationPicker(
  BuildContext context, {
  required String course,
  CourseLocation? initial,
  TextbookService? service,
}) {
  return showModalBottomSheet<CourseLocation>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) =>
        LocationPickerSheet(course: course, initial: initial, service: service),
  );
}

class LocationPickerSheet extends StatefulWidget {
  const LocationPickerSheet({
    super.key,
    required this.course,
    this.initial,
    this.service,
  });

  final String course;
  final CourseLocation? initial;

  /// 仅测试用：注入数据源，避免 widget 测试里真开数据库
  final TextbookService? service;

  @override
  State<LocationPickerSheet> createState() => _LocationPickerSheetState();
}

class _LocationPickerSheetState extends State<LocationPickerSheet> {
  late final TextbookService _service = widget.service ?? TextbookService();

  List<Textbook> _books = const [];
  Textbook? _book;
  List<Chapter> _chapters = const [];
  Map<String, List<Section>> _sections = const {};
  Chapter? _chapter;
  Section? _section;
  final Set<String> _expanded = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final books = await _service.listByCourse(widget.course);
    var book = widget.initial?.textbook;
    if (book != null && !books.any((b) => b.id == book!.id)) book = null;
    if (book == null && books.isNotEmpty) book = books.first;

    var chapters = const <Chapter>[];
    var sections = const <String, List<Section>>{};
    if (book != null) {
      chapters = await _service.chaptersOf(book.id);
      sections = await _service.sectionMapOf(book.id);
    }

    final initialChapter = widget.initial?.chapter;
    Chapter? chapter;
    if (initialChapter != null) {
      for (final c in chapters) {
        if (c.id == initialChapter.id) {
          chapter = c;
          break;
        }
      }
    }
    final initialSection = widget.initial?.section;
    Section? section;
    if (chapter != null && initialSection != null) {
      for (final s in sections[chapter.id] ?? const <Section>[]) {
        if (s.id == initialSection.id) {
          section = s;
          break;
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _books = books;
      _book = book;
      _chapters = chapters;
      _sections = sections;
      _chapter = chapter;
      _section = section;
      if (chapter != null && (sections[chapter.id] ?? const []).isNotEmpty) {
        _expanded.add(chapter.id);
      }
      _loading = false;
    });
  }

  Future<void> _switchBook(Textbook book) async {
    if (_book?.id == book.id) return;
    setState(() {
      _book = book;
      _chapters = const [];
      _sections = const {};
      _chapter = null;
      _section = null;
      _expanded.clear();
      _loading = true;
    });
    final chapters = await _service.chaptersOf(book.id);
    final sections = await _service.sectionMapOf(book.id);
    if (!mounted) return;
    setState(() {
      _chapters = chapters;
      _sections = sections;
      _loading = false;
    });
  }

  void _pickChapter(Chapter chapter) {
    setState(() {
      _chapter = chapter;
      _section = null;
      if ((_sections[chapter.id] ?? const []).isNotEmpty) {
        if (!_expanded.add(chapter.id)) _expanded.remove(chapter.id);
      }
    });
  }

  void _pickSection(Chapter chapter, Section section) {
    Navigator.of(context).pop(
      CourseLocation(
        course: widget.course,
        textbook: _book,
        chapter: chapter,
        section: section,
      ),
    );
  }

  void _confirm() {
    Navigator.of(context).pop(
      CourseLocation(
        course: widget.course,
        textbook: _book,
        chapter: _chapter,
        section: _section,
      ),
    );
  }

  void _clear() {
    Navigator.of(context)
        .pop(CourseLocation(course: widget.course));
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.82;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '定位到章节 · ${widget.course}',
                      style: const TextStyle(
                          fontSize: 15.5, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_chapter != null)
                    TextButton(
                      onPressed: _clear,
                      child: const Text('清除位置'),
                    ),
                ],
              ),
            ),
            if (_books.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final b in _books)
                      ChoiceChip(
                        label: Text(b.displayTitle,
                            style: const TextStyle(fontSize: 12)),
                        selected: _book?.id == b.id,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => _switchBook(b),
                      ),
                  ],
                ),
              ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(),
              )
            else if (_book == null)
              _buildNoTextbook()
            else if (_chapters.isEmpty)
              _buildNoToc()
            else ...[
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 8),
                  children: [
                    for (final c in _chapters) _buildChapter(c),
                  ],
                ),
              ),
              _buildFooter(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildNoTextbook() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.menu_book_outlined, size: 40, color: Colors.grey.shade400),
          const SizedBox(height: 10),
          Text(
            '这门课还没有教材',
            style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
          ),
          const SizedBox(height: 6),
          Text(
            '到「设置 → 教材管理」新建一本，再把目录粘进去。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  Widget _buildNoToc() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.list_alt_outlined, size: 40, color: Colors.grey.shade400),
          const SizedBox(height: 10),
          Text(
            '「${_book!.displayTitle}」还没录入目录',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
          ),
          const SizedBox(height: 6),
          Text(
            '到「设置 → 教材管理」里粘贴目录，就能选到节了。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  Widget _buildChapter(Chapter chapter) {
    final sections = _sections[chapter.id] ?? const <Section>[];
    final selected = _chapter?.id == chapter.id;
    final expanded = _expanded.contains(chapter.id);
    return Column(
      children: [
        ListTile(
          dense: true,
          leading: Icon(
            selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
            size: 18,
            color: selected ? Colors.indigo : Colors.grey.shade400,
          ),
          title: Text(
            chapter.displayName,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          subtitle: sections.isEmpty
              ? null
              : Text('${sections.length} 节',
                  style:
                      TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          trailing: sections.isEmpty
              ? null
              : Icon(expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18, color: Colors.grey.shade500),
          onTap: () => _pickChapter(chapter),
        ),
        if (expanded)
          for (final s in sections)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.only(left: 44, right: 16),
              leading: Icon(
                _section?.id == s.id
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 16,
                color: _section?.id == s.id
                    ? Colors.indigo
                    : Colors.grey.shade400,
              ),
              title: Text(s.displayName, style: const TextStyle(fontSize: 12.5)),
              onTap: () => _pickSection(chapter, s),
            ),
      ],
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _chapter == null
                  ? '不选也可以，直接录音时行为和以前一样'
                  : '已选：${_chapter!.displayName}'
                      '${_section == null ? '（只到章）' : ' · ${_section!.displayName}'}',
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
            ),
          ),
          FilledButton(
            onPressed: _confirm,
            child: Text(_chapter == null ? '跳过' : '确定'),
          ),
        ],
      ),
    );
  }
}