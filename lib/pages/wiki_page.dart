// lib/pages/wiki_page.dart
// 课程知识库：按课程浏览词条，查看定义与全部出处。
//
// 【为什么用「课程 → 词条 → 出处」三层而不是一个大列表】
// 用户查知识库时的心理是"我这门课学了什么"，
// 而不是"所有课的所有词条混在一起"。按课程切开，先选课再看词条，
// 也符合它作为「课程级沉淀」的定位。
//
// 【为什么待确认的要单独标出来】
// 抽取是 LLM 干的，难免把噪音当词条。默认展示时把未确认的放前面并标色，
// 用户扫一眼就能确认或删掉，知识库才不会越用越脏。
import 'package:material_ui/material_ui.dart';

import '../models/wiki_entry.dart';
import '../services/wiki_service.dart';
import 'note_detail_page.dart';

class WikiPage extends StatefulWidget {
  const WikiPage({super.key});

  @override
  State<WikiPage> createState() => _WikiPageState();
}

class _WikiPageState extends State<WikiPage> {
  final WikiService _wiki = WikiService();

  List<({String course, int count, int pending})> _courses = const [];
  String _course = '';
  List<WikiEntry> _entries = const [];
  bool _loading = true;
  String? _error;

  /// 词条 → 出处条数（列表上显示"3 处出处"）
  final Map<String, int> _sourceCounts = {};

  /// 展开中的词条
  String? _expandedId;

  WikiEntryType? _typeFilter;
  String _keyword = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final courses = await _wiki.courseOverview();
      if (!mounted) return;
      setState(() {
        _courses = courses;
        _loading = false;
      });
      if (courses.isNotEmpty) {
        // 保持当前选中的课程；没有就选第一个
        final keep = courses.any((c) => c.course == _course);
        await _selectCourse(keep ? _course : courses.first.course);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  Future<void> _selectCourse(String course) async {
    setState(() => _course = course);
    await _reloadEntries();
  }

  int _loadSeq = 0;

  Future<void> _reloadEntries() async {
    if (_course.isEmpty) return;
    // 连续输入/快速切课时，先发的慢请求可能后到；用序号丢弃过期结果
    final seq = ++_loadSeq;
    final entries = await _wiki.listByCourse(
      _course,
      type: _typeFilter,
      keyword: _keyword,
    );
    final counts = <String, int>{};
    for (final e in entries) {
      final s = await _wiki.sourcesOf(e.id);
      counts[e.id] = s.length;
    }
    if (!mounted || seq != _loadSeq) return;
    setState(() {
      _entries = entries;
      _sourceCounts
        ..clear()
        ..addAll(counts);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('课程知识库'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildError()
              : _courses.isEmpty
                  ? _buildEmpty()
                  : Column(
                      children: [
                        _buildCourseBar(),
                        _buildFilters(),
                        const Divider(height: 1),
                        Expanded(child: _buildEntryList()),
                      ],
                    ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 36, color: Colors.orange.shade700),
            const SizedBox(height: 8),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book_outlined,
                size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text('知识库还是空的',
                style: TextStyle(fontSize: 15, color: Colors.grey.shade700)),
            const SizedBox(height: 6),
            Text(
              '打开一条已经生成过笔记的课堂，\n点「加入知识库」就会自动抽取词条。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12, color: Colors.grey.shade500, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCourseBar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Row(
        children: _courses.map((c) {
          final selected = c.course == _course;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              selected: selected,
              onSelected: (_) => _selectCourse(c.course),
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${c.course} · ${c.count}',
                      style: const TextStyle(fontSize: 12.5)),
                  if (c.pending > 0) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade100,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('${c.pending} 待确认',
                          style: TextStyle(
                              fontSize: 9.5, color: Colors.orange.shade900)),
                    ),
                  ],
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildFilters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        children: [
          SizedBox(
            height: 36,
            child: TextField(
              decoration: InputDecoration(
                hintText: '筛词条名或定义…',
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20)),
              ),
              style: const TextStyle(fontSize: 13),
              onChanged: (v) {
                _keyword = v.trim();
                _reloadEntries();
              },
            ),
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _typeChip(null, '全部'),
                ...WikiEntryType.values.map((t) => _typeChip(t, t.label)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _typeChip(WikiEntryType? type, String label) {
    final selected = _typeFilter == type;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(label, style: const TextStyle(fontSize: 11.5)),
        selected: selected,
        visualDensity: VisualDensity.compact,
        onSelected: (_) {
          setState(() => _typeFilter = type);
          _reloadEntries();
        },
      ),
    );
  }

  Widget _buildEntryList() {
    if (_entries.isEmpty) {
      return Center(
        child: Text(
          _keyword.isEmpty && _typeFilter == null
              ? '这门课还没有词条'
              : '没有匹配的词条',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
        ),
      );
    }

    // 待确认的排前面：它们需要用户处理
    final sorted = [..._entries]..sort((a, b) {
        if (a.isConfirmed != b.isConfirmed) return a.isConfirmed ? 1 : -1;
        return b.updatedAt.compareTo(a.updatedAt);
      });

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: sorted.length,
      itemBuilder: (context, i) => _buildEntryCard(sorted[i]),
    );
  }

  Widget _buildEntryCard(WikiEntry entry) {
    final expanded = _expandedId == entry.id;
    final sourceCount = _sourceCounts[entry.id] ?? 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(
                () => _expandedId = expanded ? null : entry.id),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.indigo.shade50,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(entry.type.label,
                            style: TextStyle(
                                fontSize: 10,
                                color: Colors.indigo.shade700)),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(entry.term,
                            style: const TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600)),
                      ),
                      if (!entry.isConfirmed)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.orange.shade50,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text('待确认',
                              style: TextStyle(
                                  fontSize: 9.5,
                                  color: Colors.orange.shade900)),
                        ),
                      const SizedBox(width: 4),
                      Icon(
                        expanded ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                        color: Colors.grey.shade500,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(entry.definition,
                      maxLines: expanded ? null : 2,
                      overflow: expanded ? null : TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, height: 1.5)),
                  if (entry.variants.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text('也写作：${entry.variants.join('、')}',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade600)),
                  ],
                  const SizedBox(height: 4),
                  Text('$sourceCount 处出处',
                      style: TextStyle(
                          fontSize: 10.5, color: Colors.grey.shade500)),
                ],
              ),
            ),
          ),
          if (expanded) _buildSources(entry),
          if (!entry.isConfirmed)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      await _wiki.deleteEntry(entry.id);
                      await _load();
                    },
                    icon: const Icon(Icons.delete_outline, size: 15),
                    label: const Text('删掉这条',
                        style: TextStyle(fontSize: 11.5)),
                    style: TextButton.styleFrom(
                        foregroundColor: Colors.red.shade400),
                  ),
                  const SizedBox(width: 4),
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      await _wiki.confirm(entry.id);
                      await _load();
                    },
                    icon: const Icon(Icons.check, size: 15),
                    label: const Text('确认收录',
                        style: TextStyle(fontSize: 11.5)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSources(WikiEntry entry) {
    return FutureBuilder<List<WikiSource>>(
      future: _wiki.sourcesOf(entry.id),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Center(
                child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        final sources = snap.data!;
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(10, 0, 10, 6),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('出处（点标题可跳转原文）',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade700)),
              const SizedBox(height: 6),
              ...sources.map((s) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InkWell(
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  NoteDetailPage(noteId: s.noteId),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.article_outlined,
                                  size: 13, color: Colors.indigo.shade400),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  s.noteTitle,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: Colors.indigo.shade600,
                                    decoration: TextDecoration.underline,
                                  ),
                                ),
                              ),
                              if (s.conflict)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: Colors.red.shade50,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text('说法不一致',
                                      style: TextStyle(
                                          fontSize: 9,
                                          color: Colors.red.shade700)),
                                ),
                            ],
                          ),
                        ),
                        if (s.altDefinition != null) ...[
                          const SizedBox(height: 3),
                          Text('另一说法：${s.altDefinition}',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.red.shade700,
                                  height: 1.4)),
                        ],
                        const SizedBox(height: 2),
                        Text('「${s.snippet}」',
                            style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade700,
                                height: 1.4)),
                      ],
                    ),
                  )),
            ],
          ),
        );
      },
    );
  }
}