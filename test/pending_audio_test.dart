// test/pending_audio_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:classnote/services/db_service.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  setUp(() async {
    DbService.factoryOverrideForTest = databaseFactoryFfi;
    DbService.dbPathOverrideForTest = inMemoryDatabasePath;
    await DbService().resetForTest();
  });

  tearDown(() async {
    await DbService().resetForTest();
    DbService.factoryOverrideForTest = null;
    DbService.dbPathOverrideForTest = null;
  });

  test('失败音频段能登记、同段去重、按笔记与段号删除', () async {
    final db = DbService();
    await db.addPendingAudioSegment('n1', 2, '/tmp/a.wav');
    await db.addPendingAudioSegment('n1', 2, '/tmp/a2.wav'); // 同段覆盖
    await db.addPendingAudioSegment('n1', 3, '/tmp/b.wav');
    await db.addPendingAudioSegment('n2', 0, '/tmp/c.wav');

    var rows = await db.listPendingAudioSegments();
    expect(rows.length, 3);
    expect(rows.first['path'], '/tmp/a2.wav'); // 同段被替换

    await db.deletePendingAudioSegmentAt('n1', 3);
    rows = await db.listPendingAudioSegments();
    expect(rows.length, 2);
    expect(rows.any((r) => r['segment_index'] == 3), isFalse);
  });
}
