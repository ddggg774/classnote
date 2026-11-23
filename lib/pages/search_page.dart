// lib/pages/search_page.dart
// 全局检索页：跨所有笔记搜索，并支持「问 AI」跨笔记问答。
//
// 【为什么搜索页要能问 AI】
// 纯检索给的是「片段列表」，用户还得自己读完再归纳。
// 「这学期木兰科讲过几次」这种问题，检索列十条片段也没用，
// 需要一次归纳。两者并列放在同一页：搜到片段，也能直接问。
//
// 【为什么问答要标出处】
// 跨笔记归纳最容易编造（把两节课的内容混在一起说成"老师说"）。
// 强制要求答带出处 [笔记标题]，编造就无处可藏，用户能点回去核对。
import 'package:material_ui/material_ui.dart';

import '../services/rag_service.dart';
import '../services/search_index.dart';
import '../services/search_service.dart';
import '../services/settings_service.dart';
import 'note_detail_page.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final SearchService _search = SearchService();
  final RagService _rag = RagService();

  List<SearchHit> _hits = const [];
  bool _searching = false;
  String? _answer;
  bool _answering = false;
  String? _error;
  String _lastQuery = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _doSearch() async {
    final q = _controller.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
      _answer = null;
      _lastQuery = q;
    });
    try {
      final hits = await _search.search(q);
      if (!mounted) return;
      setState(() {
        _hits = hits;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _searching = false;
      });
    }
  }

  Future<void> _ask() async {
    final q = _controller.text.trim();
    if (q.isEmpty) return;
    final key = await SettingsService().getApiKey();
    if (!mounted) return;
    if (key.isEmpty) {
      setState(() => _error = '请先在「设置」里填写 DeepSeek API Key');
      return;
    }

    setState(() {
      _answering = true;
      _answer = null;
      _error = null;
    });
    try {
      // 换了关键词就必须重搜；只有「同一问题再问一次」才复用旧命中
      final needSearch = q != _lastQuery || _hits.isEmpty;
      final hits = needSearch ? await _search.search(q) : _hits;
      final result = await _rag.answer(
        question: q,
        hits: hits,
        transcriptLoader: _loadTranscript,
        apiKey: key,
      );
      if (!mounted) return;
      setState(() {
        _lastQuery = q;
        if (needSearch) _hits = hits;
        _answer = result.text;
        _answering = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _answering = false;
      });
    }
  }

  /// 按 noteId 取原文，供 RAG 拼上下文
  Future<String> _loadTranscript(String noteId) async {
    final note = await _search.noteById(noteId);
    return note?.transcript ?? '';
  }

  void _openNote(String noteId, int position) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NoteDetailPage(noteId: noteId, initialOffset: position),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('搜索笔记'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _doSearch(),
              decoration: InputDecoration(
                hintText: '搜术语、知识点、老师的话…',
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.auto_awesome, size: 20),
                        tooltip: '问 AI',
                        onPressed: _answering ? null : _ask,
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 36, color: Colors.orange.shade700),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    if (_answering) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('正在阅读相关笔记…', style: TextStyle(fontSize: 13)),
          ],
        ),
      );
    }

    if (_lastQuery.isEmpty) {
      return _buildHint();
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (_answer != null) _buildAnswerCard(_answer!),
        if (_answer != null) const SizedBox(height: 12),
        if (_hits.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Column(
                children: [
                  Icon(Icons.search_off,
                      size: 40, color: Colors.grey.shade400),
                  const SizedBox(height: 8),
                  Text('没找到「$_lastQuery」',
                      style: TextStyle(color: Colors.grey.shade600)),
                  const SizedBox(height: 4),
                  Text('换个词试试，或者点右上角 ✨ 让 AI 回答',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade500)),
                ],
              ),
            ),
          )
        else ...[
          Text('找到 ${_hits.length} 条',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          const SizedBox(height: 6),
          ..._hits.map(_buildHitCard),
        ],
      ],
    );
  }

  Widget _buildHint() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.manage_search, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text('搜遍所有课堂笔记',
                style: TextStyle(fontSize: 15, color: Colors.grey.shade700)),
            const SizedBox(height: 6),
            Text(
              '支持模糊匹配：搜「离生心皮」也能找到原文写成「离心皮」的地方',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnswerCard(String answer) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.indigo.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.indigo.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome,
                  size: 16, color: Colors.indigo.shade700),
              const SizedBox(width: 6),
              Text('AI 回答',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.indigo.shade800)),
              const Spacer(),
              if (_hits.isNotEmpty)
                Text('基于 ${_hits.length} 条笔记',
                    style: TextStyle(
                        fontSize: 11, color: Colors.indigo.shade400)),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(answer,
              style: const TextStyle(fontSize: 13.5, height: 1.6)),
        ],
      ),
    );
  }

  Widget _buildHitCard(SearchHit hit) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openNote(hit.noteId, hit.position),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(hit.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                  if (hit.course.isNotEmpty &&
                      hit.course != hit.title)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(hit.course,
                          style: TextStyle(
                              fontSize: 10, color: Colors.grey.shade700)),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              _buildHighlightedSnippet(hit.snippet, _lastQuery),
            ],
          ),
        ),
      ),
    );
  }

  /// 把命中词高亮出来。用户一眼要知道为什么这条被搜出来。
  Widget _buildHighlightedSnippet(String snippet, String query) {
    const base = TextStyle(
        fontSize: 12.5, height: 1.5, color: Colors.black87);
    const hl = TextStyle(
      fontSize: 12.5,
      height: 1.5,
      color: Colors.black,
      fontWeight: FontWeight.w700,
      backgroundColor: Color(0xFFFFF3C4),
    );

    final words = query
        .split(RegExp(r'[\s,，、;；]+'))
        .where((w) => w.trim().isNotEmpty)
        .toList();
    if (words.isEmpty) return Text(snippet, style: base);

    // 按关键词切段，中间的文字用普通样式
    final spans = <TextSpan>[];
    var rest = snippet;
    while (rest.isNotEmpty) {
      var earliest = -1;
      var matchedWord = '';
      for (final w in words) {
        final idx = rest.indexOf(w);
        if (idx >= 0 && (earliest < 0 || idx < earliest)) {
          earliest = idx;
          matchedWord = w;
        }
      }
      if (earliest < 0) {
        spans.add(TextSpan(text: rest, style: base));
        break;
      }
      if (earliest > 0) {
        spans.add(TextSpan(text: rest.substring(0, earliest), style: base));
      }
      spans.add(TextSpan(text: matchedWord, style: hl));
      rest = rest.substring(earliest + matchedWord.length);
    }
    return RichText(
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(children: spans),
    );
  }
}
