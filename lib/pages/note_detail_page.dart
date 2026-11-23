// lib/pages/note_detail_page.dart
// 笔记详情页：四个 Tab —— 原文（可编辑）、详细笔记（九段式 Markdown）、
// 思维导图、大纲（结构化的要点列表）。
// "生成总结"按钮调用 AI 服务，一次产出「详细笔记 + 思维导图结构」，存回数据库后分别渲染。
import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/academic_review.dart';
import '../models/course_location.dart';
import '../models/mind_graph.dart';
import '../models/note.dart';
import '../models/note_template.dart';
import '../models/study_note.dart';
import '../models/wiki_entry.dart';
import '../models/summary_level.dart';
import '../services/academic_review_service.dart';
import '../services/db_service.dart';
import '../services/local_vector.dart';
import '../services/wiki_search_service.dart';
import '../services/settings_service.dart';
import '../services/skill_registry.dart';
import '../services/pending_fixer.dart';
import '../services/template_service.dart';
import '../services/textbook_service.dart';
import '../services/tree_layout.dart';
import '../services/wiki_service.dart';
import '../services/ai_service.dart';
import '../services/mind_graph_exporter.dart';
import '../services/terminology_service.dart';
import '../services/transcript_corrector.dart';
import '../services/translation_service.dart';
import '../models/terminology.dart';
import '../widgets/graph_canvas.dart';
import '../widgets/location_picker.dart';
import '../widgets/mind_graph_tree.dart';
import '../widgets/mind_map_widget.dart';

class NoteDetailPage extends StatefulWidget {
  final String noteId;

  /// 从搜索结果点进来时要定位的字符偏移（-1 表示不定位）。
  /// 定位后自动切到「原文」Tab 并选中该处，
  /// 否则用户点搜索结果进来还得自己翻找。
  final int initialOffset;

  const NoteDetailPage({super.key, required this.noteId, this.initialOffset = -1});

  @override
  State<NoteDetailPage> createState() => _NoteDetailPageState();
}

class _NoteDetailPageState extends State<NoteDetailPage>
    with SingleTickerProviderStateMixin {
  final DbService _db = DbService();
  final AiService _ai = AiService();
  final TranscriptCorrector _corrector = TranscriptCorrector();
  final TerminologyService _terminologyService = TerminologyService();
  final TextbookService _textbookService = TextbookService();
  final TextEditingController _transcriptController = TextEditingController();

  /// 这条笔记对应的教材位置。老笔记为空，位置块整块不渲染。
  CourseLocation _location = CourseLocation.empty;

  /// 英语课的逐句译文。中文笔记永远是 null。
  TranslationResult? _translation;
  bool _translating = false;
  String? _translationError;
  Timer? _translateDebounce;

  /// 上次翻译时的原文，用来判断"没改就不重复花钱"
  String? _lastTranslatedText;

  /// 上一次翻译失败对应的原文（归一化）。同一段文本不自动重试，避免每保存一次就烧两次请求；
  /// 用户主动点开对照时仍会强制重试。
  String? _translationFailedFor;

  /// 正在做术语准备或质量校准
  bool _correcting = false;
  bool _wikiExtracting = false;
  bool _preparing = false;
  /// 正在保存原文（防止连点）
  bool _savingTranscript = false;
  /// 课前术语包
  TerminologyPack? _terms;
  /// 本次校准报告（四段式）
  CalibrationReport? _report;

  /// 从库里读出的、上次 Agent 跑完留下的待确认项。
  /// 与 _report 分开：_report 是本次点「质量校准」的即时结果，
  /// 这个是历史存档，两者不互相覆盖。
  List<PendingItem> _savedPending = const [];

  /// 待确认列表是否展开（默认只显示前 3 条，避免一屏几十条压垮人）
  bool _showAllReportPending = false;
  bool _showAllSavedPending = false;

  /// 上次落库时被预算压掉的条数（来自 summaryJson）
  int _savedSuppressed = 0;

  /// 报告区是否展开「被预算压掉的条目」
  bool _showSuppressed = false;

  /// 学科专家质检：结果与进行中状态
  final AcademicReviewService _academicReviewer = AcademicReviewService();
  AcademicReview? _academicReview;
  bool _reviewing = false;
  String _reviewProgress = '';

  /// 批量替换前保存的待确认快照；撤销时要连清单一起还原
  List<PendingItem>? _undoPendingSnapshot;

  /// 批量操作进行中：防止「替换」与「忽略」并发写库
  bool _pendingBusy = false;

  /// 额外技能产出（考点清单 / 复习题）
  Map<String, String> _extras = const {};
  /// 校准前的原文，用于撤销
  String? _undoTranscript;

  late TabController _tabController;
  final GlobalKey _captureKey = GlobalKey();
  final ScrollController _detailScroll = ScrollController();
  Note? _note;
  MindMapData? _mindMap;
  /// 3–5 级详细导图（主图+子图）
  MindGraph? _graph;
  /// 当前进入的二级分支；null 表示显示主图
  MindGraphNode? _activeBranch;
  /// 详细课堂笔记正文（九段式 Markdown）。为空表示还没有生成过详细笔记（老数据）。
  String _detailMarkdown = '';
  bool _summarizing = false;
  /// 总结详细度，默认标准档
  SummaryLevel _level = SummaryLevel.normal;

  /// 导图视图：树形（默认，屏幕小更好用）还是 2D 画布
  bool _useCanvas = false;

  /// 当前使用的笔记模板（为空时按课程自动推荐）
  NoteTemplate? _template;

  /// 全部可用模板（内置 + 自定义），进页面时加载一次
  List<NoteTemplate> _templates = TemplateService.builtins;
  bool _exporting = false;
  bool _notFound = false;
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    // 4 个 Tab：原文 / 详细笔记 / 思维导图 / 大纲
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging && mounted) {
        setState(() => _tabIndex = _tabController.index);
      }
    });
    _load();
  }

  /// 读取笔记，并尝试解析已有的总结。
  /// 找不到时明确置 _notFound，避免旧版那样永远转圈。
  Future<void> _load() async {
    final note = await _db.queryById(widget.noteId);
    if (!mounted) return;
    if (note == null) {
      setState(() => _notFound = true);
      return;
    }
    _transcriptController.text = note.transcript;
    // 自定义模板加载失败不该挡住笔记打开
    try {
      final custom = await _db.queryTemplates();
      if (mounted) {
        _templates = TemplateService.merge(custom: custom);
      }
    } catch (_) {}
    // StudySummary.tryDecode 兼容三种历史形态：
    // ① 新格式（带 detail）；② 旧格式（只有 mindMap）；③ 坏数据（返回 null）
    final parsed = StudySummary.tryDecode(note.summaryJson);
    final savedReview =
        AcademicReview.tryDecode(await _db.academicReviewJson(widget.noteId));
    setState(() {
      _note = note;
      _mindMap = parsed?.mindMap;
      _graph = parsed?.graph;
      _activeBranch = null;
      _terms = TerminologyPack.tryDecode(note.terminologyJson);
      _detailMarkdown = parsed?.detailMarkdown ?? '';
      _savedPending = parsed?.pending ?? const [];
      _savedSuppressed = parsed?.suppressedCount ?? 0;
      _academicReview = savedReview;
      _extras = parsed?.extras ?? const {};
      // 模板：存过就按存的来，没存过按课程推荐
      final savedTpl = note.templateId;
      _template = (savedTpl != null
              ? TemplateService.builtinById(savedTpl)
              : null) ??
          TemplateService.recommendFor(note.effectiveCourse);
    });
    await _loadLocation(note);
    _initTranslation(note);
  }

  /// 课程名：只有结构化 course 才算数。老笔记的 title 常是「11月22日第三讲」，
  /// 拿它当课程去匹配教材只会匹配出错误结果。
  String get _courseForLocation {
    final note = _note;
    if (note == null) return '';
    return (note.course ?? '').trim().isNotEmpty ? note.effectiveCourse : '';
  }

  /// 还原位置。教材/目录被改过也能逐级降级，不抛异常。
  Future<void> _loadLocation(Note note) async {
    final course = _courseForLocation;
    if (course.isEmpty || !note.hasLocation) {
      if (!mounted) return;
      setState(() => _location = CourseLocation(course: course));
      return;
    }
    final loc = await _textbookService.resolve(
      course: course,
      textbookId: note.textbookId,
      chapterNo: note.chapterNo,
      chapterTitle: note.chapterTitle,
      sectionNo: note.sectionNo,
      sectionTitle: note.sectionTitle,
    );
    if (!mounted) return;
    setState(() => _location = loc);
  }

  // ───────────────────── 英语课翻译 ─────────────────────

  /// 打开笔记时初始化译文：有缓存直接读；英语课且没译文就排一次自动翻译。
  void _initTranslation(Note note) {
    final cached = TranslationResult.tryDecode(note.translationJson);
    _translation = cached;
    // 存归一化后的文本：pairs 拼回来的句子与原稿空格/换行不同，
    // 直接比字符串会导致「没改也被判成改了」，白花一次翻译
    _lastTranslatedText =
        cached == null ? null : _normalize(cached.pairs.map((p) => p.source).join(' '));
    if (note.isEnglish && cached == null && note.transcript.trim().length >= 20) {
      _scheduleTranslate();
    }
  }

  /// 去掉空白再比较：换行、空格差异不算改动
  static String _normalize(String s) => s.replaceAll(RegExp(r'\s+'), '');

  /// 防抖 2 秒：用户连续改原文时只翻最后一次。
  void _scheduleTranslate() {
    final note = _note;
    if (note == null || !note.isEnglish) return;
    _translateDebounce?.cancel();
    _translateDebounce = Timer(const Duration(seconds: 2), () {
      _translateNow();
    });
  }

  Future<void> _translateNow({bool force = false}) async {
    final note = _note;
    if (note == null || !note.isEnglish || _translating) return;
    final text = _transcriptController.text.trim();
    if (text.length < 20) {
      if (mounted) setState(() => _translationError = '原文太短，暂不翻译');
      return;
    }
    if (!force && _normalize(text) == _lastTranslatedText) return;
    if (!force && _normalize(text) == _translationFailedFor) return;

    setState(() {
      _translating = true;
      _translationError = null;
    });
    try {
      final result = await TranslationService()
          .translate(text: text, sourceLang: note.language);
      if (!mounted) return;

      // 翻译期间用户又改了原文：这次结果已经对不上了。
      // 丢弃而不是落库——否则会把旧译文挂到新原文上，
      // 更糟的是用旧的 note 对象回写，可能把用户刚保存的原文覆盖掉。
      final latest = _transcriptController.text.trim();
      if (_normalize(latest) == _normalize(text)) {
        final current = _note;
        if (current != null) {
          final updated = current.copyWith(translationJson: result.encode());
          await _db.update(updated);
          if (!mounted) return;
          setState(() {
            _note = updated;
            _translation = result;
            _lastTranslatedText = _normalize(text);
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() =>
            _translationError = e.toString().replaceFirst('Exception: ', ''));
      }
      // 记下"这段失败过"：不再自动重试，但用户点开对照时 force 仍会重试。
      // 注意不能把 _lastTranslatedText 设成新原文——那会让旧译文被当成"最新"，
      // 用户点开对照会看到过期译文。
      _translationFailedFor = _normalize(text);
    } finally {
      if (mounted) setState(() => _translating = false);
    }
    // 翻译期间又改过 → 补一次（否则这次改动永远等不到译文）
    if (mounted && _note != null && _note!.isEnglish) {
      final latest = _transcriptController.text.trim();
      if (_normalize(latest) != _normalize(text)) _scheduleTranslate();
    }
  }

  Future<void> _openTranslation() async {
    if (_translating) return;
    final currentNorm = _normalize(_transcriptController.text.trim());
    // 原文改过而译文还是旧的：先翻再打开，别让用户看到过期对照
    if (_translation == null ||
        (_lastTranslatedText != null && currentNorm != _lastTranslatedText)) {
      await _translateNow(force: true);
    }
    if (!mounted) return;
    if (_translation == null) {
      _showSnack(_translationError ?? '翻译失败，稍后再试');
      return;
    }
    await _showTranslationSheet(_translation!);
  }

  Future<void> _showTranslationSheet(TranslationResult result) async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _TranslationSheet(result: result),
    );
    if (selected == null || !mounted) return;
    // 点某一句 → 选中原文里对应的位置
    final pair = result.pairs.where((p) => p.index == selected).toList();
    if (pair.isEmpty) return;
    final offset = _transcriptController.text.indexOf(pair.first.source);
    if (offset >= 0) {
      _transcriptController.selection =
          TextSelection.collapsed(offset: offset);
    }
  }

  /// 事后修改位置：选错了能改回来，比重新建笔记现实得多。
  Future<void> _editLocation() async {
    final note = _note;
    final course = _courseForLocation;
    if (note == null) return;
    if (course.isEmpty) {
      _showSnack('这条笔记没有课程名，无法定位教材章节');
      return;
    }
    final result = await showLocationPicker(
      context,
      course: course,
      initial: _location,
    );
    if (result == null || !mounted) return;

    final hasTextbook = result.textbook != null;
    final hasPosition = result.hasPosition;
    final updated = note.copyWith(
      textbookId: result.textbook?.id,
      chapterNo: result.chapter?.no,
      chapterTitle: result.chapter?.title,
      sectionNo: result.section?.no,
      sectionTitle: result.section?.title,
      // null 在 copyWith 里表示「不修改」，清空必须显式声明
      clearLocation: !hasTextbook,
      clearPosition: !hasPosition,
    );
    await _db.update(updated);
    if (!mounted) return;
    setState(() => _note = updated);
    await _loadLocation(updated);
  }

  /// 位置条：有位置才显示；老笔记不出现空块。
  Widget _buildLocationBar() {
    final line = _location.displayLine;
    if (line.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.indigo.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.indigo.shade100),
      ),
      child: Row(
        children: [
          Icon(Icons.place_outlined, size: 16, color: Colors.indigo.shade600),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              line,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12, height: 1.35, color: Colors.indigo.shade900),
            ),
          ),
          TextButton(
            onPressed: _editLocation,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('修改位置', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  /// 先选档位，再生成。
  /// 档位决定输出结构（brief 只有三节、detail 带原文引用），
  /// 不该让用户"生成完才发现选错了"。
  Future<void> _pickLevelThenGenerate() async {
    final picked = await _pickLevel();
    if (picked == null) return;
    await _generateSummary();
  }

  /// 选择模板与档位。返回 null 表示用户取消。
  ///
  /// 两件事放一个面板：模板决定「有哪些章节」，档位决定「写多细」，
  /// 它们是一起生效的，分开两次弹窗用户会漏选。
  Future<SummaryLevel?> _pickLevel() async {
    var level = _level;
    var template = _template ?? _templates.first;

    final picked = await showModalBottomSheet<SummaryLevel>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.8,
            ),
            child: ListView(
              shrinkWrap: true,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Row(children: [
                    Text('笔记模板',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                  ]),
                ),
                ..._templates.map((t) => ListTile(
                      dense: true,
                      leading: Icon(
                        t.id == template.id
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: t.id == template.id
                            ? Colors.indigo
                            : Colors.grey,
                      ),
                      title: Row(children: [
                        Flexible(child: Text(t.name)),
                        if (t.builtin)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.indigo.shade50,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text('内置',
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.indigo.shade700)),
                            ),
                          ),
                      ]),
                      subtitle: t.scene.isEmpty
                          ? null
                          : Text(t.scene,
                              style: TextStyle(
                                  fontSize: 11.5,
                                  color: Colors.grey.shade600)),
                      onTap: () => setSheet(() => template = t),
                    )),
                const Divider(height: 20),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Row(children: [
                    Text('详细度',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                  ]),
                ),
                ...SummaryLevel.values.map((lv) => ListTile(
                      dense: true,
                      leading: Icon(
                        lv == level
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: lv == level ? Colors.indigo : Colors.grey,
                      ),
                      title: Text(lv.label),
                      subtitle: Text(lv.description,
                          style: TextStyle(
                              fontSize: 11.5, color: Colors.grey.shade600)),
                      onTap: () => setSheet(() => level = lv),
                    )),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: FilledButton.icon(
                      onPressed: () {
                        setState(() {
                          _level = level;
                          _template = template;
                        });
                        Navigator.pop(ctx, level);
                      },
                      icon: const Icon(Icons.auto_awesome, size: 18),
                      label: Text('用「${template.name}·${level.label}」生成'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return null;
    return picked;
  }

  /// 调用 AI 生成详细笔记（同时生成思维导图），结果写回数据库。
  /// 注意：总结用的是编辑框里的当前文本，所以必须把 transcript 一起存回去，
  /// 否则库里会出现「旧原文 + 基于新原文的总结」这种对不上的数据。
  Future<void> _generateSummary() async {
    if (_note == null || _summarizing) return;
    final currentTranscript = _transcriptController.text;
    setState(() => _summarizing = true);
    try {
      final result = await _ai.summarize(
        currentTranscript,
        level: _level,
        // 用结构化课程名，老笔记自动回退 title
        courseName: _note!.effectiveCourse,
        language: _note!.language,
        template: _template,
      );
      final summaryJson = result.encode();
      final updated = _note!.copyWith(
        summaryJson: summaryJson,
        transcript: currentTranscript,
        templateId: _template?.id,
      );
      await _db.update(updated);

      if (!mounted) return;
      setState(() {
        _note = updated;
        _mindMap = result.mindMap;
        _graph = result.graph;
        _activeBranch = null;
        _detailMarkdown = result.detailMarkdown;
        _tabIndex = 1; // 跳到「详细笔记」，这是用户真正想看的东西
      });
      _tabController.animateTo(1);
      if (updated.isEnglish) _scheduleTranslate();
      if (result.chunked) {
        _showSnack('课堂较长，已分块整理后再合并成完整笔记');
      }
    } catch (e) {
      _showSnack(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _summarizing = false);
    }
  }

  /// 保存用户手动修改后的原文
  Future<void> _saveTranscript() async {
    if (_note == null || _savingTranscript) return;
    setState(() => _savingTranscript = true);
    try {
      final updated = _note!.copyWith(transcript: _transcriptController.text);
      await _db.update(updated);
      if (!mounted) return;
      setState(() {
        _note = updated;
        // 保存后撤销快照就该清了：改动已经落库，再"撤销"会与库里内容不一致
        _undoTranscript = null;
        _report = null;
      });
      _showSnack(updated.isEnglish ? '原文已保存，正在更新译文…' : '原文已保存');
      if (updated.isEnglish) _scheduleTranslate();
    } finally {
      if (mounted) setState(() => _savingTranscript = false);
    }
  }

  /// 把这条笔记抽成知识库词条。
  ///
  /// 已抽过会直接被服务层跳过（不花钱），所以可以放心让用户反复点。
  Future<void> _extractToWiki() async {
    final note = _note;
    if (note == null || _wikiExtracting) return;
    if (note.isDraft) {
      _showSnack('草稿还没有定稿，先「完成并记录」再加入知识库');
      return;
    }
    if (note.effectiveCourse.trim().isEmpty) {
      _showSnack('这条笔记没有课程名，无法归入知识库');
      return;
    }
    final key = await SettingsService().getApiKey();
    if (!mounted) return;
    if (key.isEmpty) {
      _showSnack('请先在「设置」里填写 DeepSeek API Key');
      return;
    }

    setState(() => _wikiExtracting = true);
    try {
      final result = await WikiService(apiKeyOverride: key).extractFromNote(note);
      if (!mounted) return;
      _showSnack(result.isEmpty
          ? '这条笔记已经抽过了，没有新内容'
          : '知识库：${result.summary}');
    } catch (e) {
      if (mounted) {
        _showSnack('抽取失败：${e.toString().replaceFirst('Exception: ', '')}');
      }
    } finally {
      if (mounted) setState(() => _wikiExtracting = false);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _translateDebounce?.cancel();
    _tabController.dispose();
    _transcriptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final note = _note;
    if (_notFound) {
      return Scaffold(
        appBar: AppBar(title: const Text('笔记详情')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.delete_sweep_outlined,
                    size: 64, color: Colors.grey.shade400),
                const SizedBox(height: 16),
                const Text('这条笔记已经不在了'),
                const SizedBox(height: 8),
                Text('可能已在首页被删除',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
                const SizedBox(height: 20),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('返回列表'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(note?.title ?? '笔记详情'),
        actions: [
          IconButton(
            onPressed: _reviewing ? null : _runAcademicReview,
            tooltip: '学科质检',
            icon: _reviewing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.school_outlined),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: '原文'),
            Tab(text: '详细笔记'),
            Tab(text: '思维导图'),
            Tab(text: '大纲'),
          ],
        ),
      ),
      floatingActionButton: _summarizing
          ? null
          : FloatingActionButton.extended(
              // 先选档位再生成：档位直接决定输出结构，让用户每次明确选择
              onPressed: _pickLevelThenGenerate,
              icon: const Icon(Icons.auto_awesome),
              label: Text(
                '${_detailMarkdown.isEmpty ? '一键总结' : '重新总结'}'
                '· ${_template?.name ?? '模板'}',
              ),
            ),
      // 关键：总结期间不再把整个 IndexedStack 换成 spinner。
      // 那样会清掉 Tab1 的编辑内容、Tab2/3 的滚动位置，用户每次总结都丢一次上下文。
      // 改成「保留页面 + 顶部线性进度 + 只读锁定」。
      body: note == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_summarizing)
                  const LinearProgressIndicator(minHeight: 3),
                if (_summarizing)
                  Container(
                    width: double.infinity,
                    color: Colors.indigo.shade50,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Text(
                      'AI 正在总结要点（约 10–30 秒，可用下方文字照常滚动查看）…',
                      style:
                          TextStyle(color: Colors.indigo.shade900, fontSize: 12),
                    ),
                  ),
                _buildLocationBar(),
                Expanded(
                  child: IndexedStack(
                    index: _tabIndex,
                    children: [
                      _buildTranscriptTab(),
                      _buildDetailTab(),
                      _buildMindMapTab(),
                      _buildSummaryTab(),
                    ],
                  ),
                ),
                // PNG 导出需要 MindMapWidget 真实渲染，挂在这里的 Offstage 里
                _buildPngCaptureSource(),
              ],
            ),
    );
  }

  /// Tab 1：原文（可编辑 + 保存 + 课前术语准备 + 质量校准）
  Widget _buildTranscriptTab() {
    final report = _report;
    final review = _academicReview;
    return Column(
      children: [
        if (_reviewing)
          Column(
            children: [
              const LinearProgressIndicator(minHeight: 3),
              Container(
                width: double.infinity,
                color: Colors.indigo.shade50,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(
                  _reviewProgress.isEmpty ? '学科质检中…' : '学科质检中：$_reviewProgress',
                  style: TextStyle(
                      fontSize: 12, color: Colors.indigo.shade900),
                ),
              ),
            ],
          ),
        if (review != null)
          InkWell(
            onTap: () => _showAcademicReviewSheet(review),
            child: Container(
              width: double.infinity,
              color: Colors.indigo.shade50,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.school_outlined,
                      size: 15, color: Colors.indigo.shade600),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '上次学科质检（${review.subject.label}）：'
                      '${review.issueCount} 处问题',
                      style: TextStyle(
                          fontSize: 12, color: Colors.indigo.shade900),
                    ),
                  ),
                  Text('查看',
                      style: TextStyle(
                          fontSize: 12, color: Colors.indigo.shade600)),
                ],
              ),
            ),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _transcriptController,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              // 总结期间锁住编辑：避免「总结的是改到一半的文本」这种歧义
              readOnly: _summarizing,
              style: const TextStyle(fontSize: 14.5, height: 1.6),
              decoration: InputDecoration(
                hintText: '课堂原文，可直接修改',
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ),

        // ── 报告区（可滚动，默认折叠成摘要）──
        if (report != null) _buildReportPanel(report),

        // ── 额外技能产出（考点清单 / 复习题）──
        if (_extras.isNotEmpty) _buildExtrasPanel(),

        // ── 上次「一键处理」留下的待确认（库里的，不是本次校准的）──
        if (report == null && _savedPending.isNotEmpty)
          _buildSavedPendingPanel(),

        // ── 操作区 ──
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(
            children: [
              // 英语课专属：逐句中文对照。中文笔记这里什么都不显示。
              if (_note?.isEnglish ?? false) ...[
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    onPressed: _translating ? null : _openTranslation,
                    icon: _translating
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.translate, size: 17),
                    label: Text(
                      _translating
                          ? '翻译中…'
                          : (_translation == null ? '生成中文对照' : '查看中文对照'),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
              ],
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _preparing ? null : _prepareTerminology,
                      icon: _preparing
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.menu_book_outlined, size: 17),
                      label: Text(
                        _preparing
                            ? '生成术语表…'
                            : (_terms == null ? '课前术语准备' : '术语表'),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      // 质量校准：按 A/B/C 三档规则处理，不润色不改写
                      onPressed: _correcting ? null : _calibrate,
                      icon: _correcting
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.spellcheck, size: 17),
                      label: Text(_correcting ? '校准中…' : '质量校准',
                          style: const TextStyle(fontSize: 13)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _wikiExtracting ? null : _extractToWiki,
                  icon: _wikiExtracting
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.library_add_outlined, size: 17),
                  label: Text(
                    _wikiExtracting ? '抽取词条中…' : '加入知识库',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _savingTranscript ? null : _saveTranscript,
                      icon: const Icon(Icons.save_outlined, size: 17),
                      label: const Text('保存原文',
                          style: TextStyle(fontSize: 13)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_undoTranscript != null)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _undoCalibration,
                        icon: const Icon(Icons.undo, size: 17),
                        label: const Text('撤销校准',
                            style: TextStyle(fontSize: 13)),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 四段式校准报告面板
  /// 上次「一键处理」留下的待确认项。
  /// 与本次校准报告分开显示：这是历史存档，重进页面也还在。
  Widget _buildSavedPendingPanel() {
    final shown = _showAllSavedPending
        ? _savedPending
        : _savedPending.take(3).toList();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.help_outline,
                  size: 16, color: Colors.orange.shade800),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '上次处理留下 ${_savedPending.length} 处待确认',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.orange.shade900,
                  ),
                ),
              ),
              // 全部确认后可以清掉，避免一直挂着
              TextButton(
                onPressed: _correcting ? null : _clearSavedPending,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('已核对，清除', style: TextStyle(fontSize: 11.5)),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '点一下可跳到原文对应位置回听',
            style: TextStyle(fontSize: 11, color: Colors.orange.shade700),
          ),
          if (_savedSuppressed > 0)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '另有 $_savedSuppressed 处低置信，未逐条列出',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ),
          Row(
            children: [
              TextButton(
                onPressed: _correcting ? null : _applyAllSavedFirstChoice,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('全部按首选', style: TextStyle(fontSize: 11.5)),
              ),
              TextButton(
                onPressed: _correcting ? null : _ignoreAllSaved,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('全部忽略',
                    style: TextStyle(fontSize: 11.5, color: Colors.grey)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ...shown.map((p) => InkWell(
                // 有候选就能直接选一个替换；没候选的只定位
                onTap: () => _openPendingActions(p),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 1, right: 4),
                        child: Icon(
                          p.canLocate
                              ? Icons.my_location
                              : Icons.remove_circle_outline,
                          size: 12,
                          color: p.canLocate
                              ? Colors.indigo.shade400
                              : Colors.grey.shade400,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          '${p.snippet}'
                          '${p.candidates.isNotEmpty ? '〔疑似：${p.candidates.join(' / ')}〕' : ''}'
                          '${p.count > 1 ? '（出现 ${p.count} 次）' : ''}',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: Colors.grey.shade800,
                            decoration: p.canLocate
                                ? TextDecoration.underline
                                : null,
                            decorationStyle: TextDecorationStyle.dotted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )),
          if (_savedPending.length > 3)
            TextButton(
              onPressed: () => setState(
                  () => _showAllSavedPending = !_showAllSavedPending),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                _showAllSavedPending
                    ? '收起'
                    : '展开其余 ${_savedPending.length - 3} 条',
                style:
                    TextStyle(fontSize: 11.5, color: Colors.indigo.shade600),
              ),
            ),
        ],
      ),
    );
  }

  /// 点击待确认项：有候选就让用户选一个直接替换，没候选就只定位。
  Future<void> _openPendingActions(PendingItem item) async {
    final candidates = item.candidates;
    // 没有候选 → 只能说"去看看"，别假装能改
    if (candidates.isEmpty) {
      _jumpToPending(item);
      return;
    }

    final choice = await showModalBottomSheet<_PendingAction>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '原文：${item.snippet}',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (item.count > 1)
                    Text('出现 ${item.count} 次',
                        style: TextStyle(
                            fontSize: 11.5, color: Colors.grey.shade600)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '选一个正确的写法，会直接替换进原文',
                  style: TextStyle(
                      fontSize: 11.5, color: Colors.grey.shade600),
                ),
              ),
            ),
            ...candidates.map((c) => ListTile(
                  dense: true,
                  leading:
                      const Icon(Icons.arrow_forward, size: 18, color: Colors.indigo),
                  title: Text(c, style: const TextStyle(fontSize: 14)),
                  subtitle: c == item.snippet
                      ? Text('保持原样',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade500))
                      : null,
                  onTap: () => Navigator.pop(
                    ctx,
                    _PendingAction(replacement: c),
                  ),
                )),
            const SizedBox(height: 4),
            ListTile(
              dense: true,
              leading: const Icon(Icons.my_location, size: 18),
              title: const Text('只定位，不改', style: TextStyle(fontSize: 14)),
              onTap: () => Navigator.pop(
                ctx,
                const _PendingAction(jumpOnly: true),
              ),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.check_circle_outline,
                  size: 18, color: Colors.green),
              title: const Text('这是对的，标记已核对',
                  style: TextStyle(fontSize: 14)),
              onTap: () => Navigator.pop(
                ctx,
                const _PendingAction(acceptAsIs: true),
              ),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );

    if (choice == null || !mounted) return;
    if (choice.jumpOnly) {
      _jumpToPending(item);
      return;
    }
    if (choice.acceptAsIs) {
      await _removePending(item);
      return;
    }
    await _applyPendingFix(item, choice.replacement!);
  }

  /// 执行替换：处理"多处出现"的选择，落库并重算其余待确认项位置
  Future<void> _applyPendingFix(PendingItem item, String replacement) async {
    final text = _transcriptController.text;
    final occurrences = _countOccurrences(text, item.snippet);

    // 多处出现时问一句：全替还是只替这一处
    var all = false;
    if (occurrences > 1) {
      final mode = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('替换几处？'),
          content: Text('「${item.snippet}」在原文里出现了 $occurrences 次。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'one'),
              child: const Text('只改第 1 处'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'all'),
              child: Text('全部改（$occurrences 处）'),
            ),
          ],
        ),
      );
      if (mode == null || !mounted) return;
      all = mode == 'all';
    }

    final result = PendingFixer.apply(text, item, replacement, all: all);
    if (!result.changed) {
      _showSnack('没找到「${item.snippet}」，原文可能已被改动');
      return;
    }

    // 用替换后的新正文重算其余待确认项的位置
    final remaining = PendingFixer.relocateAll(
      result.text,
      _savedPending
          .where((p) => !(p.snippet == item.snippet &&
              p.candidates.join('/') == item.candidates.join('/')))
          .toList(),
    );

    _transcriptController.text = result.text;
    await _persistPendingChange(result.text, remaining);

    if (!mounted) return;
    setState(() => _savedPending = remaining);
    _showSnack('已替换 ${result.replaced} 处：${item.snippet} → $replacement');
  }

  /// 标记已核对（不改成文字，只从清单里去掉）
  Future<void> _removePending(PendingItem item) async {
    final remaining = _savedPending
        .where((p) => !(p.snippet == item.snippet &&
            p.candidates.join('/') == item.candidates.join('/')))
        .toList();
    await _persistPendingChange(_transcriptController.text, remaining);
    if (!mounted) return;
    setState(() => _savedPending = remaining);
    _showSnack('已标记核对：${item.snippet}');
  }

  /// 把正文与待确认清单一起落库
  Future<void> _persistPendingChange(
    String newText,
    List<PendingItem> remaining,
  ) async {
    final note = _note;
    if (note == null) return;
    final parsed = StudySummary.tryDecode(note.summaryJson);
    final updated = note.copyWith(
      transcript: newText,
      summaryJson: parsed == null
          ? note.summaryJson
          : StudySummary(
              detailMarkdown: parsed.detailMarkdown,
              mindMap: parsed.mindMap,
              graph: parsed.graph,
              chunked: parsed.chunked,
              pending: remaining,
              // 预算计数跟着列表一起存，重进页面才不会「另有 N 处」消失
              suppressedCount:
                  _report?.suppressedCount ?? parsed.suppressedCount,
            ).encode(),
    );
    await _db.update(updated);
    if (!mounted) return;
    setState(() => _note = updated);
    if (updated.isEnglish) _scheduleTranslate();
  }

  static int _countOccurrences(String text, String snippet) {
    final s = snippet.trim();
    if (s.isEmpty) return 0;
    var count = 0;
    var from = 0;
    while (true) {
      final idx = text.indexOf(s, from);
      if (idx < 0) break;
      count++;
      from = idx + s.length;
      if (from >= text.length) break;
    }
    return count;
  }

  /// 清除已核对的待确认项（只清存档，不动原文与总结）
  Future<void> _clearSavedPending() async {
    final note = _note;
    if (note == null) return;
    final parsed = StudySummary.tryDecode(note.summaryJson);
    if (parsed == null) return;

    final updated = note.copyWith(
      summaryJson: StudySummary(
        detailMarkdown: parsed.detailMarkdown,
        mindMap: parsed.mindMap,
        graph: parsed.graph,
        chunked: parsed.chunked,
        pending: const [],
        suppressedCount: parsed.suppressedCount,
      ).encode(),
    );
    await _db.update(updated);
    if (!mounted) return;
    setState(() {
      _note = updated;
      _savedPending = const [];
    });
    _showSnack('已清除待确认清单');
  }

  /// 批量：把所有带候选的待确认项按「首选候选」替换。
  /// 逐条替换、每条都重算位置；替换前给一次确认，替换后仍可撤销。
  Future<void> _applyAllSavedFirstChoice() async {
    if (_pendingBusy) return;
    final targets =
        _savedPending.where((p) => p.candidates.isNotEmpty).toList();
    if (targets.isEmpty) {
      _showSnack('没有带候选的待确认项');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('按首选候选批量替换'),
        content: Text(
          '将把 ${targets.length} 处待确认按各自的首选候选替换，'
          '多次出现的会全部替换；替换后仍可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('替换'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _pendingBusy = true);
    try {
      final original = _transcriptController.text;
      final snapshot = List<PendingItem>.from(_savedPending);
      var text = original;
      var remaining = List<PendingItem>.from(_savedPending);
      var replacedTotal = 0;

      for (final item in targets) {
        // 同一片段出现多次时整条替换掉，否则删了清单还会剩下没改的旧写法
        final all = item.positions.length > 1 || item.count > 1;
        final result =
            PendingFixer.apply(text, item, item.candidates.first, all: all);
        if (!result.changed) continue;
        text = result.text;
        replacedTotal += result.replaced;
        remaining = remaining
            .where((p) =>
                !(p.snippet == item.snippet &&
                    p.candidates.join('/') == item.candidates.join('/')))
            .toList();
        remaining = PendingFixer.relocateAll(text, remaining);
      }

      if (replacedTotal == 0) {
        _showSnack('没有替换成功，原文可能已被改动');
        return;
      }

      setState(() {
        _undoTranscript = original;
        _undoPendingSnapshot = snapshot;
      });
      _transcriptController.text = text;
      await _persistPendingChange(text, remaining);
      if (!mounted) return;
      setState(() => _savedPending = remaining);
      _showSnack('已批量替换 $replacedTotal 处');
    } finally {
      if (mounted) setState(() => _pendingBusy = false);
    }
  }

  /// 批量忽略：只清清单，不改正文。先确认，SnackBar 里可撤销。
  Future<void> _ignoreAllSaved() async {
    if (_pendingBusy || _savedPending.isEmpty) return;
    final snapshot = List<PendingItem>.from(_savedPending);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('全部忽略'),
        content: Text('将清空 ${_savedPending.length} 条待确认，正文不会改动。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('忽略'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _pendingBusy = true);
    try {
      await _clearSavedPending();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('已全部忽略，正文未改动'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () async {
              await _persistPendingChange(
                  _transcriptController.text, snapshot);
              if (!mounted) return;
              setState(() => _savedPending = snapshot);
            },
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _pendingBusy = false);
    }
  }

  /// 报告区批量：按首选候选替换本次报告里的待确认项。
  /// 报告里的项还没落库，替换后要顺手写成「已保存待确认」。
  Future<void> _applyAllReportFirstChoice(CalibrationReport report) async {
    if (_pendingBusy) return;
    final targets =
        report.pending.where((p) => p.candidates.isNotEmpty).toList();
    if (targets.isEmpty) {
      _showSnack('没有带候选的待确认项');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('按首选候选批量替换'),
        content: Text(
          '将把 ${targets.length} 处待确认按各自的首选候选替换，'
          '多次出现的会全部替换；替换后仍可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('替换'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _pendingBusy = true);
    try {
      final original = _transcriptController.text;
      final snapshot = List<PendingItem>.from(_savedPending);
      var text = original;
      var remaining = List<PendingItem>.from(report.pending);
      var replacedTotal = 0;

      for (final item in targets) {
        final all = item.positions.length > 1 || item.count > 1;
        final result =
            PendingFixer.apply(text, item, item.candidates.first, all: all);
        if (!result.changed) continue;
        text = result.text;
        replacedTotal += result.replaced;
        remaining = remaining
            .where((p) =>
                !(p.snippet == item.snippet &&
                    p.candidates.join('/') == item.candidates.join('/')))
            .toList();
        remaining = PendingFixer.relocateAll(text, remaining);
      }

      if (replacedTotal == 0) {
        _showSnack('没有替换成功，原文可能已被改动');
        return;
      }

      setState(() {
        _undoTranscript = original;
        _undoPendingSnapshot = snapshot;
        _report = report.withPending(remaining);
        _savedPending = remaining;
      });
      _transcriptController.text = text;
      await _persistPendingChange(text, remaining);
      if (!mounted) return;
      _showSnack('已按首选替换 $replacedTotal 处');
    } finally {
      if (mounted) setState(() => _pendingBusy = false);
    }
  }

  /// 报告区批量忽略：清掉本次待确认（不改正文），落库时清单为空。
  Future<void> _ignoreAllReport(CalibrationReport report) async {
    if (_pendingBusy || report.pending.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('全部忽略'),
        content: Text('将清空本次 ${report.pending.length} 条待确认，正文不会改动。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('忽略'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _pendingBusy = true);
    try {
      final snapshot = List<PendingItem>.from(report.pending);
      setState(() {
        _report = report.withPending(const []);
        _savedPending = const [];
      });
      await _persistPendingChange(_transcriptController.text, const []);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('已忽略本次待确认，正文未改动'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () async {
              await _persistPendingChange(
                  _transcriptController.text, snapshot);
              if (!mounted) return;
              setState(() => _savedPending = snapshot);
            },
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _pendingBusy = false);
    }
  }

  /// 学科质检：先路由，再交给对应学科专家。
  /// 结果落库（一篇笔记一份），重开页面还能看到上次结论。
  Future<void> _runAcademicReview() async {
    final transcript = _transcriptController.text.trim();
    final source = transcript.length >= 20 ? transcript : _detailMarkdown.trim();
    if (source.isEmpty) {
      _showSnack('还没有可质检的正文');
      return;
    }

    final count = AcademicReviewService.splitSentences(source).length;
    final mode = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('学科质检'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'sentence'),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.format_list_numbered),
              title: const Text('逐句全审'),
              subtitle: Text('每句单独判，漏报最少 · 约 $count 句'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'fast'),
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.bolt),
              title: Text('快速质检'),
              subtitle: Text('整段找候选 + 复核，省时间'),
            ),
          ),
        ],
      ),
    );
    if (mode == null || !mounted) return;

    setState(() {
      _reviewing = true;
      _reviewProgress = '';
    });
    try {
      final AcademicReview review;
      if (mode == 'sentence') {
        final evidence = await _buildReviewEvidence(_note);
        final index = await _buildEvidenceIndex(_note?.effectiveCourse ?? '');
        final wikiOn = await SettingsService().getWikiSearchEnabled();
        final wiki = WikiSearchService();
        if (!mounted) return;
        review = await _academicReviewer.reviewAllSentences(
          source,
          course: _note?.course ?? '',
          evidence: evidence,
          retriever: (sentence) async {
            final out = <ReviewEvidence>[];
            if (wikiOn) {
              final snippets = await wiki.search(sentence, limit: 2);
              for (final s in snippets) {
                out.add(ReviewEvidence('${s.title}：${s.extract}',
                    source: '维基百科'));
              }
            }
            out.addAll(index
                .search(sentence, k: 2)
                .map((r) => ReviewEvidence(r.doc.text, source: r.doc.source)));
            return out;
          },
          onProgress: (done, total) {
            if (!mounted) return;
            setState(() => _reviewProgress = '已审 $done/$total 句');
          },
        );
      } else {
        // 整段质检 + 逐条单句复核：二审只留被证据确认的硬伤
        review = await _academicReviewer.reviewWithVerification(
          source,
          course: _note?.course ?? '',
        );
      }
      await _db.saveAcademicReview(
        widget.noteId,
        review.encode(),
        subject: review.subject.code,
      );
      if (!mounted) return;
      setState(() => _academicReview = review);
      _showAcademicReviewSheet(review);
    } catch (e) {
      _showSnack(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() {
          _reviewing = false;
          _reviewProgress = '';
        });
      }
    }
  }

  /// 建本课程的向量索引：已确认知识库词条 + 同课程笔记的句子。
  /// 教材正文目前没有，所以「教材段落」这一层先空着，接正文后把它加进 docs 即可。
  Future<EvidenceIndex> _buildEvidenceIndex(String course) async {
    final docs = <VectorDoc>[];
    final key = course.trim();
    if (key.isNotEmpty) {
      try {
        final entries = await WikiService()
            .listByCourse(key, status: WikiEntryStatus.confirmed);
        for (final e in entries) {
          if (e.definition.trim().isEmpty) continue;
          docs.add(VectorDoc('${e.term}：${e.definition}',
              source: '知识库', course: key));
        }
      } catch (_) {}
    }
    try {
      final passages = await _db.listTextbookPassages(key);
      for (final p in passages) {
        final text = (p['text'] as String?)?.trim() ?? '';
        if (text.isEmpty) continue;
        docs.add(VectorDoc(text, source: '教材摘录', course: key));
      }
    } catch (_) {}
    try {
      final notes = await _db.queryAll();
      for (final n in notes) {
        if (key.isNotEmpty && n.effectiveCourse != key) continue;
        for (final s in AcademicReviewService.splitSentences(n.transcript)) {
          docs.add(VectorDoc(s, source: '课堂笔记', course: key));
          if (docs.length >= 800) break;
        }
        if (docs.length >= 800) break;
      }
    } catch (_) {}
    return EvidenceIndex.build(docs);
  }

  /// 质检可引用的证据：本节术语表 + 本课程已确认的知识库词条。
  /// 只收已确认条目——把待确认词条当依据，等于用没验证的东西验证别人。
  Future<List<ReviewEvidence>> _buildReviewEvidence(Note? note) async {
    final out = <ReviewEvidence>[];
    final pack = _terms;
    if (pack != null) {
      for (final t in pack.terms) {
        final b = StringBuffer(t.term);
        if (t.definition.isNotEmpty) b.write('：${t.definition}');
        if (t.misheard.isNotEmpty) b.write('（常见误听：${t.misheard}）');
        out.add(ReviewEvidence(b.toString(), source: '术语表'));
      }
    }
    final course = note?.effectiveCourse.trim() ?? '';
    if (course.isNotEmpty) {
      try {
        final entries = await WikiService()
            .listByCourse(course, status: WikiEntryStatus.confirmed);
        for (final e in entries) {
          if (e.definition.trim().isEmpty) continue;
          out.add(ReviewEvidence(
            '${e.term}：${e.definition}',
            source: '知识库',
          ));
        }
      } catch (_) {
        // 知识库读失败不影响质检，少一层依据而已
      }
    }
    return out;
  }

  void _showAcademicReviewSheet(AcademicReview review) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, scrollController) => ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    review.agentName,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.indigo.shade50,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    review.subject.label,
                    style: TextStyle(
                        fontSize: 11, color: Colors.indigo.shade700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(review.summary,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade800)),
            if (review.hardErrors.isNotEmpty) ...[
              _reviewSectionTitle('硬伤 · 违背科学事实',
                  Colors.red.shade700),
              ...review.hardErrors.map((e) => _reviewCard(
                    title: e.originalText,
                    body: [
                      if (e.errorType.isNotEmpty) '类型：${e.errorType}',
                      if (e.reason.isNotEmpty) '为什么错：${e.reason}',
                      if (e.suggestion.isNotEmpty) '建议改成：${e.suggestion}',
                      if (e.evidence.isNotEmpty) '依据：${e.evidence}',
                      if (!e.verified) '⚠ 未经单句复核（复核调用失败）',
                    ],
                    color: Colors.red.shade50,
                    border: Colors.red.shade200,
                  )),
            ],
            if (review.logicFlaws.isNotEmpty) ...[
              _reviewSectionTitle('表述不严谨 · 可能丢分',
                  Colors.orange.shade800),
              ...review.logicFlaws.map((e) => _reviewCard(
                    title: e.originalText,
                    body: [
                      if (e.reason.isNotEmpty) e.reason,
                      if (e.suggestion.isNotEmpty) '建议：${e.suggestion}',
                    ],
                    color: Colors.orange.shade50,
                    border: Colors.orange.shade200,
                  )),
            ],
            if (review.termCorrections.isNotEmpty) ...[
              _reviewSectionTitle('术语正名', Colors.indigo.shade700),
              ...review.termCorrections.map((e) => Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.indigo.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.indigo.shade100),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${e.wrong} → ${e.correct}',
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                            TextButton(
                              onPressed: () => _applyTermCorrection(e),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8),
                                minimumSize: Size.zero,
                                tapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text('替换',
                                  style: TextStyle(fontSize: 12)),
                            ),
                          ],
                        ),
                        if (e.reason.isNotEmpty)
                          Text(
                            e.reason,
                            style: TextStyle(
                                fontSize: 11.5,
                                color: Colors.grey.shade700),
                          ),
                      ],
                    ),
                  )),
            ],
            if (review.reviewAdvice.trim().isNotEmpty) ...[
              _reviewSectionTitle('复习建议', Colors.green.shade800),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(review.reviewAdvice,
                    style: const TextStyle(fontSize: 12.5, height: 1.5)),
              ),
            ],
            const SizedBox(height: 18),
            Text(
              '质检基于笔记文本与学科常识，不替代教材和老师讲解。',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
          ],
        ),
      ),
    );
  }

  Widget _reviewSectionTitle(String text, Color color) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Text(text,
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w700, color: color)),
      );

  Widget _reviewCard({
    required String title,
    required List<String> body,
    required Color color,
    required Color border,
  }) =>
      Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600)),
            for (final line in body)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(line,
                    style:
                        TextStyle(fontSize: 11.5, color: Colors.grey.shade800)),
              ),
          ],
        ),
      );

  /// 把学科质检里的「术语正名」应用到正文。全部替换，可撤销。
  Future<void> _applyTermCorrection(AcademicTermCorrection c) async {
    final text = _transcriptController.text;
    if (!text.contains(c.wrong)) {
      _showSnack('正文里找不到「${c.wrong}」，可能已被改动');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('替换术语'),
        content: Text('把正文里的「${c.wrong}」全部替换成「${c.correct}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('替换'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final result = PendingFixer.apply(
      text,
      PendingItem(snippet: c.wrong, candidates: [c.correct]),
      c.correct,
      all: true,
    );
    if (!result.changed) {
      _showSnack('没有替换成功');
      return;
    }
    setState(() => _undoTranscript = text);
    _transcriptController.text = result.text;
    await _saveTranscript();
    _showSnack('已替换 ${result.replaced} 处：${c.wrong} → ${c.correct}');
  }

  Widget _buildReportPanel(CalibrationReport report) {
    final pendingShown = _showAllReportPending
        ? report.pending
        : report.pending.take(3).toList();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: report.isLowQuality ? Colors.orange.shade50 : Colors.green.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: report.isLowQuality
                ? Colors.orange.shade200
                : Colors.green.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ① 概要
          Row(
            children: [
              Icon(
                report.isLowQuality
                    ? Icons.warning_amber_rounded
                    : Icons.auto_fix_high,
                size: 16,
                color: report.isLowQuality
                    ? Colors.orange.shade800
                    : Colors.green.shade700,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  report.isLowQuality
                      ? '本节转写可用性偏低'
                      : '已修正 ${report.fixCount} 个术语 · '
                          '命中 ${report.hits.length} 个 · '
                          '待确认 ${report.pending.length} 处',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: report.isLowQuality
                        ? Colors.orange.shade900
                        : Colors.green.shade800,
                  ),
                ),
              ),
            ],
          ),

          // 可用性评估（质量过低时）
          if (report.isLowQuality) ...[
            const SizedBox(height: 6),
            Text(report.usability!,
                style: TextStyle(fontSize: 12, color: Colors.orange.shade900)),
          ],

          // 未出现的术语
          if (report.missedTerms.isNotEmpty) ...[
            const SizedBox(height: 8),
            _reportSectionTitle('未出现的术语（建议回听）'),
            Text(report.missedTerms.join('、'),
                style: TextStyle(fontSize: 12, color: Colors.grey.shade800)),
          ],

          // ③ 待确认清单
          if (report.pending.isNotEmpty) ...[
            const SizedBox(height: 8),
            _reportSectionTitle('待确认清单'),
            Row(
              children: [
                TextButton(
                  onPressed: _pendingBusy
                      ? null
                      : () => _applyAllReportFirstChoice(report),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('全部按首选',
                      style: TextStyle(fontSize: 11.5)),
                ),
                const SizedBox(width: 14),
                TextButton(
                  onPressed: _pendingBusy
                      ? null
                      : () => _ignoreAllReport(report),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('全部忽略',
                      style:
                          TextStyle(fontSize: 11.5, color: Colors.grey)),
                ),
              ],
            ),
            ...pendingShown.map((p) => InkWell(
                  // 有候选就能选替换；没候选且能定位就只定位
                  onTap: (p.candidates.isNotEmpty || p.canLocate)
                      ? () => _openPendingActions(p)
                      : null,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (p.canLocate)
                          Padding(
                            padding: const EdgeInsets.only(top: 1, right: 4),
                            child: Icon(Icons.my_location,
                                size: 12, color: Colors.indigo.shade400),
                          )
                        else
                          const Padding(
                            padding: EdgeInsets.only(top: 1, right: 4),
                            child: Text('·', style: TextStyle(fontSize: 12)),
                          ),
                        Expanded(
                          child: Text(
                            '${p.snippet}'
                            '${p.candidates.isNotEmpty ? '〔疑似：${p.candidates.join(' / ')}〕' : ''}'
                            '${p.count > 1 ? '（出现 ${p.count} 次）' : ''}'
                            '${p.timestamp != null ? ' @${p.timestamp}' : ''}',
                            style: TextStyle(
                                fontSize: 11.5,
                                color: Colors.grey.shade800,
                                decoration: p.canLocate
                                    ? TextDecoration.underline
                                    : null,
                                decorationStyle: TextDecorationStyle.dotted),
                          ),
                        ),
                      ],
                    ),
                  ),
                )),
            if (report.pending.length > 3)
              TextButton(
                onPressed: () => setState(
                    () => _showAllReportPending = !_showAllReportPending),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  _showAllReportPending
                      ? '收起'
                      : '展开其余 ${report.pending.length - 3} 条',
                  style: TextStyle(
                      fontSize: 11.5, color: Colors.indigo.shade600),
                ),
              ),
            if (report.suppressedCount > 0)
              Row(
                children: [
                  Flexible(
                    child: Text(
                      '另有 ${report.suppressedCount} 处低置信，未逐条列出',
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    ),
                  ),
                  if (report.suppressedPending.isNotEmpty)
                    TextButton(
                      onPressed: () => setState(
                          () => _showSuppressed = !_showSuppressed),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        _showSuppressed
                            ? '收起'
                            : '查看 ${report.suppressedPending.length} 条',
                        style: TextStyle(
                            fontSize: 11, color: Colors.indigo.shade600),
                      ),
                    ),
                ],
              ),
            if (_showSuppressed && report.suppressedPending.isNotEmpty)
              ...report.suppressedPending.map((p) => Padding(
                    padding: const EdgeInsets.only(left: 4, top: 2),
                    child: Text(
                      '· ${p.snippet}'
                      '${p.candidates.isNotEmpty ? '〔疑似：${p.candidates.join(' / ')}〕' : ''}'
                      '${p.count > 1 ? '（出现 ${p.count} 次）' : ''}',
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    ),
                  )),
            if (report.droppedCount > 0)
              Text(
                '另有 ${report.droppedCount} 处噪音（单字/数字）已自动忽略',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
          ],

          // ④ 拾音建议
          if (report.micAdvice.isNotEmpty) ...[
            const SizedBox(height: 8),
            _reportSectionTitle('拾音改进建议'),
            ...report.micAdvice.map((a) => Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('· $a',
                      style: TextStyle(
                          fontSize: 11.5, color: Colors.grey.shade800)),
                )),
          ],
        ],
      ),
    );
  }

  Widget _reportSectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade700)),
      );

  /// 课前术语准备：根据课程信息生成术语表 / initial_prompt / 拾音风险提示。
  /// 结果存进 notes.terminology_json，供后续校准使用。
  Future<void> _prepareTerminology() async {
    final note = _note;
    if (note == null || _preparing) return;

    final courseCtrl = TextEditingController(
        text: _courseForLocation.isNotEmpty ? _courseForLocation : note.title);
    // 位置已经记在笔记里时，章节与教材名直接带出来，别让用户再手打一遍
    final topicCtrl = TextEditingController(text: _location.chapterKey);
    final materialCtrl = TextEditingController(text: _location.materialLine);
    final knownCtrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('课前术语准备'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: courseCtrl,
                decoration: const InputDecoration(
                    labelText: '课程名', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: topicCtrl,
                decoration: const InputDecoration(
                    labelText: '本章节主题', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: materialCtrl,
                decoration: const InputDecoration(
                    labelText: '教材/PPT 标题（可选）',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: knownCtrl,
                maxLines: 3,
                decoration: const InputDecoration(
                    labelText: '已知专有名词（可选，逗号分隔）',
                    border: OutlineInputBorder()),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('生成')),
        ],
      ),
    );
    if (ok != true) return;

    final course = courseCtrl.text.trim();
    final topic = topicCtrl.text.trim();
    final material = materialCtrl.text.trim();
    final known = knownCtrl.text.trim();
    // 先读值，等对话框关闭动画播完再 dispose。
    // 直接在这里 dispose 会崩：showDialog 返回只是路由开始出栈，
    // 关闭动画期间 TextField 仍挂在树上引用这些 controller，
    // 释放后会抛 "A TextEditingController was used after being disposed"。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      courseCtrl.dispose();
      topicCtrl.dispose();
      materialCtrl.dispose();
      knownCtrl.dispose();
    });

    if (course.isEmpty) {
      _showSnack('课程名不能为空');
      return;
    }

    setState(() => _preparing = true);
    try {
      final pack = await _terminologyService.prepare(
        courseName: course,
        topic: topic,
        material: material,
        knownTerms: known,
        language: note.language,
      );
      final updated =
          note.copyWith(terminologyJson: pack.encode());
      await _db.update(updated);
      if (!mounted) return;
      setState(() {
        _note = updated;
        _terms = pack;
      });
      _showTerminologySheet(pack);
    } catch (e) {
      _showSnack(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  /// 展示术语表（可复制 initial_prompt）
  void _showTerminologySheet(TerminologyPack pack) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.92,
        expand: false,
        builder: (ctx, scrollController) => ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Row(
              children: [
                const Text('本节课术语表',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                Text('${pack.terms.length} 条',
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade600)),
              ],
            ),
            const SizedBox(height: 10),
            ...TermLevel.values.expand((level) {
              final list = pack.byLevel(level);
              if (list.isEmpty) return <Widget>[];
              return [
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Text('${level.label}优先级（${level.meaning}）',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.indigo.shade800)),
                ),
                ...list.map((t) => Padding(
                      padding: const EdgeInsets.only(left: 4, top: 2),
                      child: Text('· ${t.display}',
                          style: const TextStyle(fontSize: 12.5)),
                    )),
              ];
            }),
            if (pack.initialPrompt.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('initial_prompt',
                  style:
                      TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              SelectableText(pack.initialPrompt,
                  style: TextStyle(
                      fontSize: 12, color: Colors.grey.shade800)),
              const SizedBox(height: 4),
              Text(
                '硅基流动的识别接口不支持 initial_prompt，所以本 App 会把它'
                '注入到「质量校准」的提示词里使用；需要时也可复制到支持该参数的工具。',
                style:
                    TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ],
            if (pack.riskHints.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('本节课拾音风险',
                  style:
                      TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              ...pack.riskHints.map((h) => Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('· $h',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade800)),
                  )),
            ],
          ],
        ),
      ),
    );
  }

  /// 质量校准：按 A/B/C 三档规则处理，不润色、不补全。
  /// 结果先写进编辑框但不落库，用户点「保存原文」才生效。
  Future<void> _calibrate() async {
    if (_note == null || _correcting) return;
    final original = _transcriptController.text;
    if (original.trim().length < 10) {
      _showSnack('内容太短，不需要校准');
      return;
    }
    setState(() => _correcting = true);
    try {
      final rawReport =
          await _corrector.calibrate(original,
              pack: _terms, language: _note?.language ?? 'zh');
      // 用「纠错前的原文」定位，不能用 annotatedText——
      // 后者插了 〔改：…〕 之类的标注，偏移量和用户看到的对不上。
      final report = rawReport.withLocations(original);
      if (!mounted) return;
      setState(() {
        _undoTranscript = original;
        if (report.hasText) _transcriptController.text = report.annotatedText;
        _report = report;
      });
      if (report.isLowQuality) {
        _showSnack('本节转写质量偏低，已给出可用性评估而非强行纠错');
      } else {
        _showSnack('已校准：修正 ${report.fixCount} 处，'
            '待确认 ${report.pending.length} 处');
      }
    } catch (e) {
      _showSnack(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _correcting = false);
    }
  }

  /// 待确认项的选择结果
  /// （放私有类里，避免污染全局命名空间）

  /// 点击待确认项：跳到「原文」Tab 并选中对应片段。
  ///
  /// 【为什么跳原文而不是纠错后的文本】
  /// 用户回听核对的对象是原始录音，原文才是他要听的那个版本。
  /// 而且节点位置是按原文算的，跳到标注过的文本会错位。
  void _jumpToPending(PendingItem item) {
    final pos = item.firstPosition;
    if (pos == null) return;

    // 切到「原文」Tab
    if (_tabIndex != 0) {
      setState(() => _tabIndex = 0);
      _tabController.animateTo(0);
    }

    // 选中片段：把光标区间设成整段，用户一眼能看到是哪个词
    final text = _transcriptController.text;
    final end = (pos + item.snippet.length).clamp(0, text.length);
    if (pos >= 0 && pos < text.length) {
      _transcriptController.selection =
          TextSelection(baseOffset: pos, extentOffset: end);
    }

    _showSnack(item.count > 1
        ? '已定位「${item.snippet}」，全文共出现 ${item.count} 次，这是第 1 处'
        : '已定位「${item.snippet}」，请回听这段录音核对');
  }

  Future<void> _undoCalibration() async {
    final original = _undoTranscript;
    if (original == null) return;
    final snapshot = _undoPendingSnapshot;
    _transcriptController.text = original;
    if (snapshot != null) {
      // 批量替换过：正文与待确认清单都要回到替换前，并重新落库
      await _persistPendingChange(original, snapshot);
      if (!mounted) return;
      setState(() {
        _savedPending = snapshot;
        _undoTranscript = null;
        _undoPendingSnapshot = null;
        _report = null;
      });
    } else {
      setState(() {
        _undoTranscript = null;
        _report = null;
      });
    }
    _showSnack('已撤销');
  }

  /// 点画布节点时弹一个小面板显示正文（不跳走，保持画布位置）
  void _showCanvasNodeInfo(LayoutNode node) {
    if (node.details.isEmpty && node.childIndices.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(node.title,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                  ),
                  if (node.mark != NodeMark.none)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(node.mark.name,
                          style: TextStyle(
                              fontSize: 9.5, color: Colors.amber.shade900)),
                    ),
                ],
              ),
              if (node.relation != null && node.relation!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('与上级的关系：${node.relation}',
                    style: TextStyle(
                        fontSize: 11.5, color: Colors.grey.shade600)),
              ],
              if (node.details.isNotEmpty) ...[
                const SizedBox(height: 10),
                ...node.details.map((d) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('· ',
                              style: TextStyle(color: Colors.grey.shade500)),
                          Expanded(
                            child: Text(d,
                                style: const TextStyle(
                                    fontSize: 12.5, height: 1.5)),
                          ),
                        ],
                      ),
                    )),
              ],
              const SizedBox(height: 6),
              Text(
                node.childIndices.isEmpty
                    ? '叶子节点'
                    : '有 ${node.childIndices.length} 个子节点（双击可折叠）',
                style:
                    TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Tab 2：文字版总结（要点列表）
  Widget _buildSummaryTab() {
    if (_mindMap == null) return _buildEmptyHint('还没有总结，点右下角「一键总结」生成');
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(_mindMap!.root,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        ..._mindMap!.nodes.asMap().entries.map((entry) {
          final idx = entry.key + 1;
          final node = entry.value;
          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$idx. ${node.topic}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  ...node.children.map((c) => Padding(
                        padding: const EdgeInsets.only(left: 12, top: 2),
                        child: Text('• $c', style: const TextStyle(fontSize: 14, height: 1.5)),
                      )),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  /// Tab 2：详细笔记（九段式 Markdown，可复制/导出）
  /// 额外技能产出（考点清单 / 复习题）的展示区块。
  /// 折叠起来：它们不是每次都要看，但想复习时能立刻展开。
  Widget _buildExtrasPanel() {
    if (_extras.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      decoration: BoxDecoration(
        color: Colors.teal.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.teal.shade100),
      ),
      child: Column(
        children: _extras.entries.map((e) {
          final title = switch (e.key) {
            BuiltinSkill.examPoints => '考点清单',
            BuiltinSkill.quiz => '复习题',
            _ => e.key,
          };
          return ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 12),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            dense: true,
            leading: Icon(
              e.key == BuiltinSkill.quiz
                  ? Icons.quiz_outlined
                  : Icons.star_outline,
              size: 18,
              color: Colors.teal.shade700,
            ),
            title: Text(title,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.teal.shade900)),
            subtitle: Text('${e.value.length} 字',
                style: TextStyle(fontSize: 11, color: Colors.teal.shade400)),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                e.value,
                style: const TextStyle(fontSize: 12.5, height: 1.6),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildDetailTab() {
    if (_detailMarkdown.isEmpty) {
      return _buildEmptyHint('还没有详细笔记，点右下角「一键总结」生成\n'
          '（会整理成知识点、例题、作业提示等九个部分）');
    }
    return Column(
      children: [
        Expanded(
          child: Scrollbar(
            controller: _detailScroll,
            child: SingleChildScrollView(
              controller: _detailScroll,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: SelectableText(
                _detailMarkdown,
                style: const TextStyle(fontSize: 14.5, height: 1.65),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _copyDetail,
                  icon: const Icon(Icons.copy_all, size: 18),
                  label: const Text('复制全文'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _exportDetailMarkdown,
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: const Text('导出 .md'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 复制详细笔记全文（方便贴到自己的笔记软件里二次编辑）
  Future<void> _copyDetail() async {
    await Clipboard.setData(ClipboardData(text: _detailMarkdown));
    _showSnack('已复制全文');
  }

  /// 把详细笔记导出成 .md 文件并调起系统分享
  Future<void> _exportDetailMarkdown() async {
    if (_detailMarkdown.isEmpty || _exporting) return;
    final box = context.findRenderObject() as RenderBox?;
    final origin =
        box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    setState(() => _exporting = true);
    try {
      final dir = await getTemporaryDirectory();
      final safeTitle =
          _note!.title.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5]'), '_');
      final file = File('${dir.path}/课堂笔记_$safeTitle.md');
      await file.writeAsString(_detailMarkdown);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/markdown')],
          text: '「${_note!.title}」详细课堂笔记',
          sharePositionOrigin: origin,
        ),
      );
    } catch (e) {
      _showSnack('导出失败：${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Tab 3：思维导图（主图 + 子图）
  ///
  /// 交互：默认显示「主图」——课程主题 + 11 个一级分支；
  /// 点某个分支进入「子图」——该分支下 3–5 级的完整层级（可折叠）。
  /// 这样主图永远不拥挤，详细内容都在子图里。
  Widget _buildMindMapTab() {
    if (_graph == null || _graph!.branches.isEmpty) {
      return _buildEmptyHint('还没有思维导图，点右下角「一键总结」生成');
    }
    final graph = _graph!;
    final branch = _activeBranch;

    return Column(
      children: [
        // 子图时显示返回条
        if (branch != null)
          Container(
            width: double.infinity,
            color: Colors.indigo.shade50,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: () => setState(() => _activeBranch = null),
                  icon: const Icon(Icons.arrow_back, size: 16),
                  label: const Text('返回主图', style: TextStyle(fontSize: 12.5)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                  ),
                ),
                Expanded(
                  child: Text(
                    branch.title,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.indigo.shade900,
                    ),
                  ),
                ),
              ],
            ),
          ),
        // 视图切换：画布看全局，树看细节
        if (branch == null)
          Container(
            width: double.infinity,
            color: Colors.grey.shade50,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Row(
              children: [
                Icon(
                  _useCanvas ? Icons.account_tree : Icons.view_list,
                  size: 14,
                  color: Colors.grey.shade600,
                ),
                const SizedBox(width: 6),
                Text(
                  _useCanvas ? '画布视图（看全局）' : '树形视图（看细节）',
                  style: TextStyle(
                      fontSize: 11.5, color: Colors.grey.shade700),
                ),
                const Spacer(),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('树形')),
                    ButtonSegment(value: true, label: Text('画布')),
                  ],
                  selected: {_useCanvas},
                  onSelectionChanged: (v) =>
                      setState(() => _useCanvas = v.first),
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    textStyle: WidgetStateProperty.all(
                        const TextStyle(fontSize: 11.5)),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: branch == null
              ? (_useCanvas
                  ? GraphCanvas(
                      graph: graph,
                      onNodeTap: (node) => _showCanvasNodeInfo(node),
                    )
                  : MindGraphOverview(
                      graph: graph,
                      onBranchTap: (b) => setState(() => _activeBranch = b),
                    ))
              : MindGraphSubtree(branch: branch),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _exporting ? null : _showExportSheet,
                  icon: _exporting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.ios_share, size: 18),
                  label: const Text('导出导图'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _exporting ? null : _exportMindMapPng,
                  icon: const Icon(Icons.image_outlined, size: 18),
                  label: const Text('导出图片'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 选择导出格式（Markdown / Markmap / Mermaid / OPML / JSON）
  Future<void> _showExportSheet() async {
    final graph = _graph;
    if (graph == null) return;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  const Text('导出思维导图',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Text('${graph.totalNodes} 节点 / ${graph.maxDepth} 级',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade600)),
                ],
              ),
            ),
            ...MindGraphExporter.formats.map((f) => ListTile(
                  dense: true,
                  leading: Icon(_iconForFormat(f.key), size: 20),
                  title: Text(f.label, style: const TextStyle(fontSize: 14)),
                  subtitle: Text('.${f.ext}',
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade500)),
                  onTap: () => Navigator.pop(ctx, f.key),
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    await _exportGraph(chosen);
  }

  static IconData _iconForFormat(String key) {
    switch (key) {
      case 'md':
        return Icons.article_outlined;
      case 'markmap':
        return Icons.language;
      case 'mermaid':
        return Icons.account_tree_outlined;
      case 'opml':
        return Icons.list_alt;
      case 'json':
        return Icons.data_object;
      default:
        return Icons.description_outlined;
    }
  }

  /// 把导图按指定格式落盘并调起系统分享
  Future<void> _exportGraph(String formatKey) async {
    final graph = _graph;
    if (graph == null || _exporting) return;
    final box = context.findRenderObject() as RenderBox?;
    final origin =
        box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    setState(() => _exporting = true);
    try {
      final text = MindGraphExporter.render(graph, formatKey);
      final ext = MindGraphExporter.extOf(formatKey);
      final dir = await getTemporaryDirectory();
      final safeTitle =
          _note!.title.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5]'), '_');
      final file = File('${dir.path}/思维导图_$safeTitle.$ext');
      await file.writeAsString(text);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          text: '「${_note!.title}」思维导图',
          sharePositionOrigin: origin,
        ),
      );
    } catch (e) {
      _showSnack('导出失败：${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 导出 PNG（用旧的 MindMapWidget 截长图，保留给需要图片的场景）
  Future<void> _exportMindMapPng() async {
    if (_mindMap == null || _exporting) return;
    final box = context.findRenderObject() as RenderBox?;
    final origin =
        box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    setState(() => _exporting = true);
    try {
      final bytes = await MindMapWidget.exportPng(_captureKey);
      final dir = await getTemporaryDirectory();
      final safeTitle =
          _note!.title.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5]'), '_');
      final file = File('${dir.path}/导图_$safeTitle.png');
      await file.writeAsBytes(bytes);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          text: '「${_note!.title}」思维导图',
          sharePositionOrigin: origin,
        ),
      );
    } catch (e) {
      _showSnack('导出失败：${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 隐藏的截图源：PNG 导出需要 MindMapWidget 真实渲染在树上，
  /// 放在 Offstage 里既不影响布局又保证 RepaintBoundary 可截图。
  Widget _buildPngCaptureSource() {
    if (_mindMap == null) return const SizedBox.shrink();
    return Offstage(
      offstage: true,
      child: SizedBox(
        width: 420,
        child: MindMapWidget(data: _mindMap!, captureKey: _captureKey),
      ),
    );
  }

  Widget _buildEmptyHint(String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.auto_awesome_outlined, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}

/// 待确认项弹窗的选择结果
class _PendingAction {
  /// 用户选定的正确写法（替换用）
  final String? replacement;

  /// 只定位不改
  final bool jumpOnly;

  /// 标记为正确，直接移除
  final bool acceptAsIs;

  const _PendingAction({
    this.replacement,
    this.jumpOnly = false,
    this.acceptAsIs = false,
  });
}

/// 英语课的中文对照面板：一句原文、一句译文，上下排列。
/// 点某一句会把它在原文里的位置选中（返回 index 给调用方）。
class _TranslationSheet extends StatelessWidget {
  const _TranslationSheet({required this.result});

  final TranslationResult result;

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.8;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('中文对照',
                        style: TextStyle(
                            fontSize: 15.5, fontWeight: FontWeight.w600)),
                  ),
                  Text(
                    result.isPerSentence ? '逐句 · 点句子回到原文' : '整段翻译',
                    style: TextStyle(
                        fontSize: 11.5, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                itemCount: result.pairs.length,
                separatorBuilder: (_, __) =>
                    Divider(height: 18, color: Colors.grey.shade200),
                itemBuilder: (ctx, i) {
                  final pair = result.pairs[i];
                  return InkWell(
                    onTap: result.isPerSentence
                        ? () => Navigator.of(context).pop(pair.index)
                        : null,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          pair.source,
                          style: TextStyle(
                              fontSize: 13.5,
                              height: 1.5,
                              color: Colors.grey.shade800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          pair.target,
                          style: TextStyle(
                              fontSize: 14,
                              height: 1.55,
                              color: Colors.indigo.shade900),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
