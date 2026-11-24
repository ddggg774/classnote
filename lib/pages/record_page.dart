// lib/pages/record_page.dart
// 记录页：支持两种把内容变成文字的方式——
// ① 点「录音」说话，录完自动上传硅基流动识别，文字按段追加到框里（云端方案，不挑手机）；
// ② 直接用手机输入法的麦克风 / 手动打字 / 粘贴，文字进框。
//
// 【改动要点（相对旧版）】
// - 识别回调加 mounted 守卫：录音中按返回不会再把文字写进已销毁的 Controller。
// - 录音中禁止「完成并记录」，并在返回时二次确认：不允许一点就 pop 掉正在录的内容。
// - 时长改为「实际录音秒数」，不再从打开页面开始算。
// - 顶部常驻状态条：已录时长 / 第几段 / 已成功段数 / 失败段可一键补传。
// - 识别期间只覆盖半透明遮罩，不替换整页，避免清掉用户正在编辑的内容与滚动位置。
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import '../agent/classroom_agent.dart';
import '../models/class_mode.dart';
import '../models/course_location.dart';
import '../models/mind_graph.dart';
import '../config.dart';
import '../models/note.dart';
import '../models/study_note.dart';
import '../models/summary_level.dart';
import '../models/terminology.dart';
import '../models/textbook.dart';
import '../services/cloud_asr_service.dart';
import '../services/db_service.dart';
import '../services/settings_service.dart';
import '../services/skill_registry.dart';
import '../services/template_service.dart';
import '../services/textbook_service.dart';
import '../widgets/agent_run_sheet.dart';
import '../widgets/location_picker.dart';

class RecordPage extends StatefulWidget {
  const RecordPage({super.key, this.draftId, this.mode = ClassMode.chinese});

  /// 传入草稿 ID 时表示「继续编辑一条未完成的笔记」
  final String? draftId;

  /// 普通课堂 / 英语课。英语课只换入口、标题与语言，录音引擎完全复用。
  final ClassMode mode;

  @override
  State<RecordPage> createState() => _RecordPageState();
}

class _RecordPageState extends State<RecordPage> with WidgetsBindingObserver {
  final DbService _db = DbService();
  final CloudAsrService _asr = CloudAsrService();
  final TextEditingController _titleController = TextEditingController();

  /// 结构化课程归属。为空时表示用户没选，保存时 course 留空、读的时候回退 title。
  /// 模板匹配、术语表检索都依赖它，所以值得单独一个字段而不是从标题猜。
  String? _course;
  final TextEditingController _transcriptController = TextEditingController();

  /// 这节课的位置（教材 → 章 → 节）。没选就是空的，下游全部拿不到章节，
  /// 行为与改造前一模一样——这是「允许跳过」的实现方式。
  Textbook? _textbook;
  Chapter? _chapter;
  Section? _section;
  final TextbookService _textbookService = TextbookService();

  CourseLocation get _location => CourseLocation(
        course: _course ?? '',
        textbook: _textbook,
        chapter: _chapter,
        section: _section,
      );

  /// 正在等待「停止 → 最后一段识别完成」的收尾过程
  bool _recognizing = false;

  /// 「一键处理」正在跑（Agent 全流程）
  bool _agentRunning = false;

  /// 草稿行 ID：录音一开始就落库，之后每完成一段就更新它，
  /// 这样崩溃/误退后还能从首页把内容找回来。
  String? _draftId;
  String _lastSavedTranscript = '';
  Timer? _autosaveTimer;
  bool _wasInBackgroundDuringRecording = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _draftId = widget.draftId;
    if (widget.draftId != null) {
      _loadDraft(widget.draftId!);
    }
    // 每 10 秒把当前文本落一次库（用户手动打字也算），避免纯手输内容丢失
    _autosaveTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _persistDraft(force: false);
    });
  }

  Future<void> _loadDraft(String id) async {
    final note = await _db.queryById(id);
    if (note == null || !mounted) return;
    _titleController.text = note.title;
    _course = note.course;
    _transcriptController.text = note.transcript;
    _lastSavedTranscript = note.transcript;

    // 位置：老的草稿没有这五个字段，hasLocation 为 false 就跳过，
    // 不猜、不报错。教材被删过也没关系，resolve 会逐级降级。
    if ((note.course ?? '').trim().isNotEmpty && note.hasLocation) {
      final loc = await _textbookService.resolve(
        course: note.effectiveCourse,
        textbookId: note.textbookId,
        chapterNo: note.chapterNo,
        chapterTitle: note.chapterTitle,
        sectionNo: note.sectionNo,
        sectionTitle: note.sectionTitle,
      );
      if (!mounted) return;
      _textbook = loc.textbook;
      _chapter = loc.chapter;
      _section = loc.section;
    }
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      if (_asr.isRecording) _wasInBackgroundDuringRecording = true;
      unawaited(_persistDraft(force: true));
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_onResumed());
    }
  }

  /// 回到前台：先跟录音器的真实状态对一次账，再刷新界面。
  /// 系统可能在后台悄悄掐掉麦克风，而 Dart 侧的标志位不会自己变 ——
  /// 不核对的话界面会一直显示「停止录音」，用户完全不知道已经录不进去了。
  Future<void> _onResumed() async {
    final wasInterrupted = await _asr.syncRecorderState();
    if (!mounted) return;
    if (wasInterrupted) {
      _wasInBackgroundDuringRecording = false;
      await _persistDraft(force: true);
    } else if (_wasInBackgroundDuringRecording) {
      _wasInBackgroundDuringRecording = false;
      if (!_asr.isRecording) {
        _showSnack('刚才切到后台时录音被系统中断了，已录内容已保存为草稿');
      }
    }
    if (mounted) setState(() {}); // 刷新按钮状态
  }

  /// 增量写入草稿。没有任何内容时不建空草稿。
  /// 补传成功：把正文里的失败占位换成真实文字，并删掉待补传登记
  Future<void> _replaceSegmentPlaceholder(int idx, String text) async {
    final marker = RegExp('〔第 ${idx + 1} 段语音识别失败[^〕]*〕');
    final current = _transcriptController.text;
    final next = marker.hasMatch(current)
        ? current.replaceAll(marker, text)
        : '$current\n〔补传 第 ${idx + 1} 段〕\n$text';
    _transcriptController.text = next;
    await _persistDraft(force: true);
    final id = _draftId;
    if (id != null) {
      await _db.deletePendingAudioSegmentAt(id, idx);
    }
  }

  /// 某段永久失败：登记到「未完成的音频段」，用户可在设置里补传
  Future<void> _recordFailedSegment(int idx, String path) async {
    await _persistDraft(force: true);
    final id = _draftId;
    if (id == null) return;
    await _db.addPendingAudioSegment(id, idx, path);
  }

  Future<void> _persistDraft({required bool force}) async {
    final text = _transcriptController.text;
    if (!force && text == _lastSavedTranscript) return;
    if (text.trim().isEmpty && (_draftId == null)) return;

    final title = _titleController.text.trim().isEmpty
        ? '未命名课堂'
        : _titleController.text.trim();

    if (_draftId == null) {
      final id = const Uuid().v4();
      await _db.insert(Note(
        id: id,
        title: title,
        transcript: text,
        createdAt: DateTime.now(),
        duration: _asr.recordedSeconds,
        status: Note.statusDraft,
        course: _course,
        textbookId: _textbook?.id,
        chapterNo: _chapter?.no,
        chapterTitle: _chapter?.title,
        sectionNo: _section?.no,
        sectionTitle: _section?.title,
        language: widget.mode.languageCode,
      ));
      // 插入成功后再记 id：提前赋值会让并发保存查不到行而静默丢弃
      _draftId = id;
    } else {
      final existing = await _db.queryById(_draftId!);
      if (existing == null) {
        // 草稿在首页被删了：用同一个 id 复活，别让后续保存全部静默失败
        await _db.insert(Note(
          id: _draftId!,
          title: title,
          transcript: text,
          createdAt: DateTime.now(),
          duration: _asr.recordedSeconds,
          status: Note.statusDraft,
          course: _course,
          language: widget.mode.languageCode,
        ));
        return;
      }
      await _db.update(existing.copyWith(
        title: title,
        transcript: text,
        duration: _asr.recordedSeconds,
        // 课程与位置也要跟着草稿落库：否则杀进程后恢复出来的是「无课程草稿」
        course: _course,
        textbookId: _textbook?.id,
        chapterNo: _chapter?.no,
        chapterTitle: _chapter?.title,
        sectionNo: _section?.no,
        sectionTitle: _section?.title,
        // 清空位置后 copyWith 的 null 是「不修改」，必须显式清
        clearLocation: _textbook == null,
        clearPosition: _chapter == null,
        // 取消选课程后保存：copyWith 的 null 是「不修改」，课程会一直挂着旧值
        clearCourse: (_course ?? '').trim().isEmpty,
        language: widget.mode.languageCode,
      ));
    }
    _lastSavedTranscript = text;
  }

  /// 每段识别完成后，把文字追加到文本框。
  /// 关键点 1：mounted 守卫 —— 页面已销毁时直接丢弃，绝不碰已 dispose 的 Controller。
  /// 关键点 2：只有用户当前没有正在用输入法组合时才整体覆盖；
  ///          否则把新内容挂起，等组合结束（或用户失焦）再并入，避免打断中文输入。
  void _appendText(String text) {
    if (!mounted) return;
    final current = _transcriptController.text;
    final value = _transcriptController.value;
    final composing = value.composing.isValid && !value.composing.isCollapsed;

    if (composing) {
      _pendingInsert.add(text);
      return;
    }

    final atEnd = value.selection.isCollapsed &&
        value.selection.baseOffset == current.length;
    if (current.isEmpty) {
      _transcriptController.text = text;
    } else if (atEnd) {
      _transcriptController.text = '$current\n$text';
      _transcriptController.selection = TextSelection.collapsed(
        offset: _transcriptController.text.length,
      );
    } else {
      // 用户光标在中间：把新段落追加到末尾，但把光标留在原处，不打断阅读/编辑
      final offset = value.selection.baseOffset;
      _transcriptController.text = '$current\n$text';
      _transcriptController.selection =
          TextSelection.collapsed(offset: offset.clamp(0, _transcriptController.text.length));
    }
    setState(() {});
    _persistDraft(force: true);
  }

  final List<String> _pendingInsert = [];

  void _flushPendingInsert() {
    if (!mounted || _pendingInsert.isEmpty) return;
    final incoming = _pendingInsert.join('\n');
    _pendingInsert.clear();
    _appendText(incoming);
  }

  /// 录音按钮：点一下开始（一直录、自动分段），再点一下停止并等最后一段识别完
  Future<void> _toggleRecord() async {
    if (_recognizing) return;

    if (_asr.isRecording) {
      setState(() => _recognizing = true);
      try {
        await _asr.stopRecording();
        await _persistDraft(force: true);
        if (mounted) {
          _showSnack('转写完成，可检查文字后保存');
        }
      } catch (e) {
        if (mounted) _showSnack('处理失败：$e');
      } finally {
        if (mounted) setState(() => _recognizing = false);
      }
      return;
    }

    final hasMic = await _asr.hasPermission();
    if (!hasMic) {
      if (mounted) {
        _showSnack('请先允许麦克风权限：手机设置 → 应用 → 课堂笔记 → 权限');
      }
      return;
    }
    try {
      await _asr.startRecording(
        onText: _appendText,
        onReplaceSegment: _replaceSegmentPlaceholder,
        onSegmentFailed: _recordFailedSegment,
        onError: (msg) {
          if (!mounted) return;
          _showSnack(msg);
          setState(() {});
        },
      );
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) _showSnack('无法开始录音：$e');
    }
  }

  /// 一键处理：把这节课的文本交给顶层编排 Agent，自动完成
  /// 「转写 → 纠错 → 总结 → 导图」，并把结果落库。
  ///
  /// 【为什么录音要先停】
  /// Agent 拿到的必须是"已经定稿的文本"。录音还在跑时文本会继续增长，
  /// 拿着半截文本去总结，用户看到的笔记会和最终转写对不上。
  /// 所以这里先停录并等最后一段识别完，和 _finishAndSave 的处理一致。
  Future<void> _runAgentPipeline() async {
    if (_agentRunning) return;

    // ① 先把录音收尾，确保文本定稿
    if (_asr.isRecording) {
      await _toggleRecord();
      if (!mounted || _asr.isRecording) return;
    }

    final text = _transcriptController.text.trim();
    if (text.isEmpty) {
      _showSnack('还没有内容，先录一段或输入文字吧');
      return;
    }
    if (text.length < 30) {
      _showSnack('内容太短（${text.length} 字），至少 30 字再处理');
      return;
    }

    // ② 取 API Key
    final key = await SettingsService().getApiKey();
    if (!mounted) return;
    if (key.isEmpty) {
      _showSnack('请先在「设置」里填写 DeepSeek API Key');
      return;
    }

    // ③ 选档位
    final options = await _pickAgentOptions();
    if (options == null || !mounted) return;

    // ④ 标题：没填就用「课程名 + 日期」，别让笔记叫「未命名课堂」
    final title = _titleController.text.trim().isEmpty
        ? '课堂 ${DateTime.now().month}月${DateTime.now().day}日'
        : _titleController.text.trim();

    setState(() => _agentRunning = true);
    try {
      final agent = ClassroomAgent(apiKey: key);
      // 按设置页的启停状态 + 课程适用性组装技能集合。
      // Agent 会据此收窄提示词与工具——关掉的技能真的调不到。
      final courseForSkills = (_course ?? '').trim().isNotEmpty
          ? _course!.trim()
          : title;
      final skills =
          await SkillRegistry().resolve(courseName: courseForSkills);
      if (skills.isEmpty) {
        if (mounted) {
          _showSnack('没有启用任何技能，请到「设置」里至少打开一个');
          setState(() => _agentRunning = false);
        }
        return;
      }
      if (!mounted) return;
      final result = await showModalBottomSheet<ClassroomResult>(
        context: context,
        isScrollControlled: true,
        isDismissible: false,
        enableDrag: false,
        builder: (_) => AgentRunSheet(
          agent: agent,
          skills: skills,
          request: ClassroomRequest(
            // 课程优先用用户选的，没选才退回标题——
            // 模板匹配与术语表都要准确的课程名，不能靠标题猜。
            courseName: (_course ?? '').trim().isNotEmpty
                ? _course!.trim()
                : title,
            chapter: _location.chapterKey,
            language: widget.mode.languageCode,
            level: options.level,
            existingTranscript: text,
            wantMindMap: options.wantMindMap,
            // 课程决定模板：制图课自动用制图模板，其余九段式
            template: TemplateService.recommendFor(
              (_course ?? '').trim().isNotEmpty ? _course!.trim() : title,
            ),
            // 音频已在录音阶段转写完，这里不再传片段：
            // Agent 的 transcribe 只处理"还没转写的音频"，
            // 重复转写会白花钱。
          ),
        ),
      );

      if (!mounted) return;
      if (result == null) {
        _showSnack('已取消处理');
        return;
      }
      await _saveAgentResult(result, title, text);
    } catch (e) {
      if (mounted) {
        _showSnack('处理失败：${e.toString().replaceFirst('Exception: ', '')}');
      }
    } finally {
      if (mounted) setState(() => _agentRunning = false);
    }
  }

  /// 选档位与是否要导图
  Future<QuickRunOptions?> _pickAgentOptions() async {
    var level = SummaryLevel.normal;
    var wantMindMap = true;

    return showModalBottomSheet<QuickRunOptions>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Row(children: [
                  Text('一键处理',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ]),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'AI 会依次做：术语纠错 → 生成总结 → 生成思维导图',
                  style: TextStyle(fontSize: 12),
                ),
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
              SwitchListTile(
                dense: true,
                value: wantMindMap,
                onChanged: (v) => setSheet(() => wantMindMap = v),
                title: const Text('同时生成思维导图'),
                subtitle: Text('关掉可省一次调用',
                    style: TextStyle(
                        fontSize: 11.5, color: Colors.grey.shade600)),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.pop(
                      ctx,
                      QuickRunOptions(
                          level: level, wantMindMap: wantMindMap),
                    ),
                    icon: const Icon(Icons.auto_awesome, size: 18),
                    label: const Text('开始处理'),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  /// 把 Agent 的产物落库（草稿转正 + 写总结 + 写术语待确认）
  Future<void> _saveAgentResult(
    ClassroomResult result,
    String title,
    String originalText,
  ) async {
    final finalText = result.finalText ?? originalText;
    final summaryJson = _buildSummaryJson(result);

    final existing = _draftId == null ? null : await _db.queryById(_draftId!);

    if (existing != null) {
      await _db.update(existing.copyWith(
        title: title,
        transcript: finalText,
        summaryJson: summaryJson,
        duration: _asr.recordedSeconds,
        status: Note.statusDone,
        course: _course,
        textbookId: _textbook?.id,
        chapterNo: _chapter?.no,
        chapterTitle: _chapter?.title,
        sectionNo: _section?.no,
        sectionTitle: _section?.title,
        // 位置被清空时 copyWith 的 null 等于「不修改」，必须显式声明清除
        clearLocation: _textbook == null,
        clearPosition: _chapter == null,
        // 取消选课程后保存：copyWith 的 null 是「不修改」，课程会一直挂着旧值
        clearCourse: (_course ?? '').trim().isEmpty,
        language: widget.mode.languageCode,
      ));
    } else {
      // 草稿为空（用户直接贴文本进来）或者处理期间被别处删掉了：
      // 结果不能静默丢，另存一条新笔记——白跑一趟 Agent 比多一条记录更难受。
      await _db.insert(Note(
        id: const Uuid().v4(),
        title: title,
        transcript: finalText,
        summaryJson: summaryJson,
        createdAt: DateTime.now(),
        duration: _asr.recordedSeconds,
        status: Note.statusDone,
        course: _course,
        textbookId: _textbook?.id,
        chapterNo: _chapter?.no,
        chapterTitle: _chapter?.title,
        sectionNo: _section?.no,
        sectionTitle: _section?.title,
        language: widget.mode.languageCode,
      ));
    }

    if (!mounted) return;
    // 处理完直接退出记录页，回列表；用户点进去就能看新笔记
    Navigator.of(context).pop();
    _showSnack('已生成笔记：${result.summary?.length ?? 0} 字详细笔记');
  }

  /// 把 Agent 结果拼成 App 现有格式的 summaryJson。
  /// 复用 StudySummary 的编码格式，保证详情页的解析逻辑不用改。
  ///
  /// 只落详细笔记：按流程导图要在正文定稿后单独生成，
  /// Agent 顺带产出的导图不写库，避免和之后替换的正文不一致。
  String? _buildSummaryJson(ClassroomResult result) {
    final md = (result.summary ?? '').trim();
    if (md.isEmpty) return null;

    return StudySummary(
      detailMarkdown: md,
      graph: const MindGraph(root: '', branches: []),
      // 待确认项必须落库：否则用户退出详情页再进来就看不到，
      // 「点击定位」也失去了对象。
      pending: _buildPendingItems(result),
      extras: result.extras,
    ).encode();
  }

  /// Agent 返回的是纯文本形式的待确认描述，这里转成可持久化的结构，
  /// 并顺手在正文里定位——落库时就带上位置，
  /// 详情页读出来直接可点，不用再算一遍。
  List<PendingItem> _buildPendingItems(ClassroomResult result) {
    if (result.pendingNotes.isEmpty) return const [];
    final source = result.finalText ?? '';
    final items = <PendingItem>[];
    for (final note in result.pendingNotes) {
      // pendingNotes 的格式是 "片段〔疑似：候选〕" 或 "〔缺失〕描述"
      if (note.startsWith('〔缺失〕')) {
        items.add(PendingItem(snippet: note.substring(4).trim()));
        continue;
      }
      final m = RegExp(r'^(.*?)(?:〔疑似：(.*?)〕)?$').firstMatch(note);
      final snippet = (m?.group(1) ?? note).trim();
      final candRaw = m?.group(2) ?? '';
      final candidates = candRaw
          .split('/')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      items.add(PendingItem(snippet: snippet, candidates: candidates));
    }
    // 用原文定位，保证详情页点击能跳对位置
    final located = CalibrationReport(
      annotatedText: '',
      pending: items,
    ).withLocations(source);
    // 落库前把 count 补成真实出现次数：Agent 传过来的是纯文本，没有 count，
    // 不补的话界面永远显示「出现 1 次」，用户会以为只错了一处。
    return located.pending.map((p) {
      final count = p.positions.length > p.count ? p.positions.length : p.count;
      return PendingItem(
        snippet: p.snippet,
        candidates: p.candidates,
        count: count,
        timestamp: p.timestamp,
        positions: p.positions,
      );
    }).toList();
  }


  /// 完成并记录：先确保录音已收尾，再保存
  Future<void> _finishAndSave() async {
    if (_asr.isRecording) {
      // 录音中点这个按钮：先停录并转写完，再保存，避免丢掉当前段
      await _toggleRecord();
      if (!mounted || _asr.isRecording) return;
    }

    final text = _transcriptController.text.trim();
    if (text.isEmpty) {
      if (mounted) _showSnack('还没有内容，先录一段或输入文字吧');
      return;
    }

    final title = _titleController.text.trim().isEmpty
        ? '未命名课堂'
        : _titleController.text.trim();

    await _persistDraft(force: true);

    if (_draftId != null) {
      final existing = await _db.queryById(_draftId!);
      if (existing != null) {
        // 把草稿「转正」：补齐标题与真实录音时长，并把状态改为已完成
        await _db.update(existing.copyWith(
          title: title,
          transcript: text,
          duration: _asr.recordedSeconds,
          status: Note.statusDone,
          course: _course,
          textbookId: _textbook?.id,
          chapterNo: _chapter?.no,
          chapterTitle: _chapter?.title,
          sectionNo: _section?.no,
          sectionTitle: _section?.title,
          // 位置被清空时 copyWith 的 null 等于「不修改」，必须显式声明清除
          clearLocation: _textbook == null,
          clearPosition: _chapter == null,
          // 取消选课程后保存：copyWith 的 null 是「不修改」，课程会一直挂着旧值
          clearCourse: (_course ?? '').trim().isEmpty,
        language: widget.mode.languageCode,
        ));
      }
    } else {
      await _db.insert(Note(
        id: const Uuid().v4(),
        title: title,
        transcript: text,
        createdAt: DateTime.now(),
        duration: _asr.recordedSeconds,
        status: Note.statusDone,
        course: _course,
        textbookId: _textbook?.id,
        chapterNo: _chapter?.no,
        chapterTitle: _chapter?.title,
        sectionNo: _section?.no,
        sectionTitle: _section?.title,
        language: widget.mode.languageCode,
      ));
    }
    if (mounted) Navigator.of(context).pop();
  }

  /// 位置条：录音前定「教材 → 章 → 节」。
  ///
  /// 为什么常驻在课程选择器下面：上课时用户可能赶时间，需要一眼看到
  /// 「今天定位到哪」，也需要能随时改。不选时这里只是一行浅灰提示，
  /// 不挡路——跳过定位直接录音的行为与改造前完全一致。
  Widget _buildLocationBar() {
    final loc = _location;
    final hasPosition = loc.hasPosition;
    final courseChosen = (_course ?? '').trim().isNotEmpty;
    final hint = !courseChosen
        ? '选课程后可定位到教材章节'
        : hasPosition
            ? loc.displayLine
            : '未选章节（可跳过）';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: hasPosition ? Colors.indigo.shade50 : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: hasPosition ? Colors.indigo.shade100 : Colors.grey.shade300,
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.place_outlined,
            size: 16,
            color: hasPosition ? Colors.indigo.shade600 : Colors.grey.shade500,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              hint,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: hasPosition
                    ? Colors.indigo.shade900
                    : Colors.grey.shade700,
              ),
            ),
          ),
          if (hasPosition)
            IconButton(
              icon: const Icon(Icons.close, size: 15),
              tooltip: '清除位置',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                setState(() {
                  _textbook = null;
                  _chapter = null;
                  _section = null;
                });
                unawaited(_persistDraft(force: true));
              },
            ),
          TextButton(
            onPressed: _pickLocation,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(hasPosition ? '修改' : '定位',
                style: const TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
  }

  /// 打开位置选择面板。取消（返回 null）时保持原选择不变。
  Future<void> _pickLocation() async {
    final course = (_course ?? '').trim();
    if (course.isEmpty) {
      _showSnack('先选一门课，再定位章节');
      return;
    }
    final result = await showLocationPicker(
      context,
      course: course,
      initial: _location,
    );
    if (result == null || !mounted) return;
    setState(() {
      _textbook = result.textbook;
      _chapter = result.chapter;
      _section = result.section;
    });
    // 选完位置立刻落一次草稿：否则用户不继续打字就杀进程，位置会丢
    unawaited(_persistDraft(force: true));
  }

  /// 课程选择行。
  ///
  /// 为什么不让用户直接填：课程名是模板匹配、术语表检索、Wiki 组织的键。
  /// 自由填写会写出「11月22日第三讲」这种无法匹配的值。
  /// 这里给三个教材课程做快捷选择 + 「自定义」，一次点击就能定准。
  Widget _buildCoursePicker() {
    final selected = (_course ?? '').trim();
    final options = <String>[
      for (final t in AppConfig.textbooks) t.course,
    ];
    final isPreset = options.contains(selected);

    return Row(
      children: [
        Icon(Icons.school_outlined,
            size: 18, color: Colors.grey.shade600),
        const SizedBox(width: 8),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final o in options)
                ChoiceChip(
                  label: Text(o, style: const TextStyle(fontSize: 12)),
                  selected: selected == o,
                  visualDensity: VisualDensity.compact,
                  onSelected: (v) => setState(() {
                    final next = v ? o : null;
                    // 换课程 = 换教材，旧位置必须清掉，否则会拿 A 课的章节去查 B 课
                    if (next != _course) {
                      _textbook = null;
                      _chapter = null;
                      _section = null;
                    }
                    _course = next;
                  }),
                ),
              if (selected.isNotEmpty && !isPreset)
                // 自定义课程名不在预设里，单独显示以便取消
                InputChip(
                  label: Text(selected, style: const TextStyle(fontSize: 12)),
                  selected: true,
                  onDeleted: () => setState(() => _course = null),
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
        ),
      ],
    );
  }

  /// 输入自定义课程名
  Future<void> _pickCustomCourse() async {
    final ctrl = TextEditingController(text: _course ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('课程名'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '例如：植物学',
            helperText: '写课程名，不要写「第三讲」这种——模板和术语表要靠它匹配',
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
    // 对话框关闭动画期间 TextField 仍会引用 controller，延后释放
    WidgetsBinding.instance.addPostFrameCallback((_) => ctrl.dispose());
    if (result == null || !mounted) return;
    final next = result.isEmpty ? null : result;
    if (next != _course) {
      _textbook = null;
      _chapter = null;
      _section = null;
    }
    setState(() => _course = next);
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autosaveTimer?.cancel();
    // 离开页面前尽力把内容落库（dispose 不能 await，所以放到独立异步任务里）
    final draftId = _draftId;
    final finalText = _transcriptController.text;
    final finalSeconds = _asr.recordedSeconds;
    if (draftId != null && finalText != _lastSavedTranscript) {
      unawaited(_flushOnDispose(draftId, finalText, finalSeconds));
    }
    _asr.dispose();
    _titleController.dispose();
    _transcriptController.dispose();
    super.dispose();
  }

  /// 页面销毁后的最后一次落库，失败不打扰用户（下次进草稿仍能看到上次成功保存的内容）
  Future<void> _flushOnDispose(String draftId, String text, int seconds) async {
    try {
      final n = await _db.queryById(draftId);
      if (n == null) return;
      await _db.update(n.copyWith(transcript: text, duration: seconds));
    } catch (_) {
      // 忽略：磁盘满/被系统杀进程等场景，已有 10 秒自动保存兜底
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AsrProgress>(
      valueListenable: _asr.progress,
      builder: (context, p, _) {
        final recording = _asr.isRecording;
        return PopScope(
          canPop: !recording && !_recognizing,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return;
            final leave = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('录音还在进行'),
                content: Text(recording
                    ? '现在退出会停止录音。已转写的文字已存为草稿，可在首页「未完成」里继续。'
                    : '正在转写最后一段，现在退出会丢失尚未返回的文字。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('继续等待')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('退出')),
                ],
              ),
            );
            if (leave == true) {
              if (_asr.isRecording) await _asr.stopRecording();
              // 转写中退出：把剩余段标失败，别让它们只在内存里凭空消失
              if (_recognizing) _asr.abandonPendingSegments();
              await _persistDraft(force: true);
              if (!mounted) return;
              Navigator.of(this.context).pop();
            }
          },
          child: Scaffold(
            appBar: AppBar(title: Text(widget.mode.appBarTitle)),
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _titleController,
                      decoration: InputDecoration(
                        labelText: '课程名称（可留空）',
                        hintText: '例如：高等数学 第三讲',
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12)),
                        prefixIcon: const Icon(Icons.edit),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _buildCoursePicker(),
                    const SizedBox(height: 8),
                    _buildLocationBar(),
                    const SizedBox(height: 12),

                    if (widget.mode.translates) ...[
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.teal.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.teal.shade100),
                        ),
                        child: Text(
                          '英语课：识别语言由模型自动判断，转写后会自动给出逐句中文对照；'
                          '术语表保留英文原文 + 中文释义，总结里写成「中文（English）」。',
                          style: TextStyle(
                              fontSize: 11.5,
                              height: 1.4,
                              color: Colors.teal.shade800),
                        ),
                      ),
                    ],

                    if (recording || _recognizing || p.failedSegments > 0)
                      _buildStatusBar(p),

                    const SizedBox(height: 12),
                    Expanded(
                      child: Stack(
                        children: [
                          TextField(
                            controller: _transcriptController,
                            maxLines: null,
                            expands: true,
                            textAlignVertical: TextAlignVertical.top,
                            style: const TextStyle(fontSize: 16, height: 1.6),
                            onTapOutside: (_) {
                              FocusScope.of(context).unfocus();
                              _flushPendingInsert();
                            },
                            decoration: InputDecoration(
                              hintText: '录音识别的文字会自动出现在这里；也可以直接打字或粘贴…',
                              filled: true,
                              fillColor: Colors.grey.shade100,
                              contentPadding: const EdgeInsets.all(14),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide:
                                    BorderSide(color: Colors.grey.shade300),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide:
                                    BorderSide(color: Colors.grey.shade300),
                              ),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                          if (_recognizing)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.white70,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        CircularProgressIndicator(),
                                        SizedBox(height: 12),
                                        Text('正在转写最后几段…'),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),

                    Row(
                      children: [
                        Text(
                          '${_transcriptController.text.length} 字',
                          style: TextStyle(
                              color: Colors.grey.shade600, fontSize: 12),
                        ),
                        if (_draftId != null) ...[
                          const SizedBox(width: 8),
                          Icon(Icons.cloud_done_outlined,
                              size: 14, color: Colors.green.shade600),
                          Text(' 已自动保存草稿',
                              style: TextStyle(
                                  color: Colors.green.shade700, fontSize: 12)),
                        ],
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

                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed: _recognizing ? null : _toggleRecord,
                        icon: _recognizing
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : Icon(recording ? Icons.stop : Icons.mic),
                        label: Text(
                          _recognizing
                              ? '正在转写最后一段…'
                              : recording
                                  ? '停止录音（已录 ${AsrProgress.formatSeconds(p.recordedSeconds)}）'
                                  : '开始录音（一直录，自动转写）',
                          style: const TextStyle(fontSize: 18),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: recording ? Colors.red : Colors.indigo,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(26)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),

                    // 一键处理：交给 Agent 自动跑完纠错→总结→导图
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: FilledButton.icon(
                        onPressed: (_recognizing || _agentRunning ||
                                (!recording &&
                                    _transcriptController.text.trim().isEmpty))
                            ? null
                            : _runAgentPipeline,
                        icon: _agentRunning
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.auto_awesome),
                        label: Text(_agentRunning ? 'AI 处理中…' : '一键处理'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      height: 46,
                      child: OutlinedButton.icon(
                        // 录音中点击不置灰，而是先自动停止并转写完成再保存（见 _finishAndSave）
                        onPressed: _recognizing ||
                                _agentRunning ||
                                (!recording &&
                                    _transcriptController.text.trim().isEmpty)
                            ? null
                            : _finishAndSave,
                        icon: const Icon(Icons.check),
                        label: const Text('仅保存，稍后处理'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 常驻状态条：录音时长、段进度、失败段补传
  Widget _buildStatusBar(AsrProgress p) {
    final hasFail = p.failedSegments > 0;
    final bg = hasFail ? Colors.orange.shade50 : Colors.indigo.shade50;
    final border = hasFail ? Colors.orange.shade200 : Colors.indigo.shade100;
    final fg = hasFail ? Colors.orange.shade900 : Colors.indigo.shade900;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                hasFail ? Icons.error_outline : Icons.graphic_eq,
                size: 18,
                color: fg,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '已录 ${AsrProgress.formatSeconds(p.recordedSeconds)}'
                  ' · 第 ${p.segmentNo} 段'
                  '${p.segmentElapsed > 0 ? '（本段 ${p.segmentElapsed}s/${CloudAsrService.chunkSeconds}s）' : ''}'
                  ' · 已转写 ${p.doneSegments} 段'
                  '${p.pendingSegments > 0 ? ' · 排队 ${p.pendingSegments} 段' : ''}',
                  style: TextStyle(color: fg, fontSize: 12.5),
                ),
              ),
            ],
          ),
          if (p.notice != null) ...[
            const SizedBox(height: 6),
            Text(p.notice!,
                style: TextStyle(
                    color: Colors.blueGrey.shade700,
                    fontSize: 12,
                    fontStyle: FontStyle.italic)),
          ],
          if (hasFail) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '有 ${p.failedSegments} 段没能识别（正文里已标出位置）',
                    style: TextStyle(color: fg, fontSize: 12.5),
                  ),
                ),
                TextButton(
                  onPressed: () => _asr.retryFailedSegments(),
                  child: const Text('重试失败段'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
