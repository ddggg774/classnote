// lib/pages/pending_audio_page.dart
// 未完成的音频段：转写失败/中断后保留的 wav，可在这里补传。
//
// 为什么单独一页：录完就退出的场景里，内存里的队列和页面一起没了；
// 只有把「段号 + 文件 + 属于哪篇笔记」写进库，用户才有第二次机会。
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../services/cloud_asr_service.dart';
import '../services/db_service.dart';

class PendingAudioPage extends StatefulWidget {
  const PendingAudioPage({super.key});

  @override
  State<PendingAudioPage> createState() => _PendingAudioPageState();
}

class _PendingAudioPageState extends State<PendingAudioPage> {
  final _db = DbService();
  final _asr = CloudAsrService();
  List<Map<String, Object?>> _rows = const [];
  final Map<String, String> _titles = {};
  bool _loading = true;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await _db.listPendingAudioSegments();
    final titles = <String, String>{};
    for (final r in rows) {
      final noteId = r['note_id'] as String? ?? '';
      if (titles.containsKey(noteId)) continue;
      final note = await _db.queryById(noteId);
      titles[noteId] = note?.title ?? '（笔记已删除）';
    }
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _titles
        ..clear()
        ..addAll(titles);
      _loading = false;
    });
  }

  Future<void> _retry(Map<String, Object?> row) async {
    final id = row['id'] as String? ?? '';
    final noteId = row['note_id'] as String? ?? '';
    final idx = (row['segment_index'] as num?)?.toInt() ?? 0;
    final path = row['path'] as String? ?? '';
    if (!File(path).existsSync()) {
      _snack('音频文件已不存在，只能删除这条记录');
      return;
    }
    setState(() => _busyId = id);
    try {
      String? text;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          text = await _asr.recognize(path);
          break;
        } on AsrException catch (e) {
          if (!e.retryable || attempt == 2) rethrow;
          await Future<void>.delayed(
              Duration(milliseconds: 500 * (attempt + 1)));
        }
      }
      final note = await _db.queryById(noteId);
      if (note == null) {
        _snack('这篇笔记已被删除，无法补写');
        return;
      }
      final marker = RegExp('〔第 ${idx + 1} 段语音识别失败[^〕]*〕');
      final body = text?.trim() ?? '';
      final next = marker.hasMatch(note.transcript)
          ? note.transcript.replaceAll(marker, body)
          : '${note.transcript}\n〔补传 第 ${idx + 1} 段〕\n$body';
      await _db.update(note.copyWith(transcript: next));
      await _db.deletePendingAudioSegment(id);
      try {
        await File(path).delete();
      } catch (_) {}
      if (!mounted) return;
      _snack('第 ${idx + 1} 段已补传并写回笔记');
      await _load();
    } catch (e) {
      _snack('补传失败：${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _remove(Map<String, Object?> row) async {
    final id = row['id'] as String? ?? '';
    final path = row['path'] as String? ?? '';
    await _db.deletePendingAudioSegment(id);
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    await _load();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('未完成的音频段')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _rows.isEmpty
              ? const Center(child: Text('没有待补传的音频'))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _rows.length,
                  itemBuilder: (ctx, i) {
                    final row = _rows[i];
                    final noteId = row['note_id'] as String? ?? '';
                    final idx = (row['segment_index'] as num?)?.toInt() ?? 0;
                    final ts = DateTime.fromMillisecondsSinceEpoch(
                        (row['created_at'] as num?)?.toInt() ?? 0);
                    final busy = _busyId == row['id'];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        dense: true,
                        title: Text(
                          '${_titles[noteId] ?? noteId} · 第 ${idx + 1} 段',
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: Text(
                          '${ts.year}-${ts.month.toString().padLeft(2, '0')}-'
                          '${ts.day.toString().padLeft(2, '0')} '
                          '${ts.hour.toString().padLeft(2, '0')}:'
                          '${ts.minute.toString().padLeft(2, '0')}',
                          style: const TextStyle(fontSize: 11.5),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                              onPressed: busy ? null : () => _retry(row),
                              child: Text(busy ? '补传中…' : '补传'),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18),
                              onPressed: busy ? null : () => _remove(row),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}