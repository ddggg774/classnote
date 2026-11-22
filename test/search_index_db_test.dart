// test/search_index_db_test.dart
// 检索索引的真实 SQL 测试（用 sqflite_common_ffi，内存数据库，不碰真实数据）。
//
// 为什么要真测 SQL：索引一致性是检索最容易出问题的环节——
//   · 改了笔记但索引没更新 → 搜到旧内容
//   · 删了笔记但索引残留 → 搜到已删除的笔记
// 这类 bug 用纯函数测试根本测不出来，必须真建表真插入。
//
// 注：FFI 版 SQLite 在桌面跑，与 Android 系统 SQLite 是同一套 SQL 语义。
// 它验证不了「FTS5 是否编译进来」，但本项目本来就不用 FTS5。
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:classnote/services/search_index.dart';

void main() {
  // FFI 初始化是全局一次性的
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late SearchIndex index;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE notes (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        transcript TEXT NOT NULL,
        summary_json TEXT,
        created_at INTEGER NOT NULL,
        duration INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'done',
        terminology_json TEXT,
        course TEXT,
        template_id TEXT
      )
    ''');
    await SearchIndex.createTables(db);
    index = SearchIndex(() => db);
  });

  tearDown(() async {
    await db.close();
  });

  group('索引建表与写入', () {
    test('建表可重入（迁移会重复调用）', () async {
      // 再调一次不应该抛「表已存在」
      await SearchIndex.createTables(db);
      await SearchIndex.createTables(db);
    });

    test('索引一条文档后能查到', () async {
      await index.indexDoc(const IndexDoc(
        noteId: 'n1',
        title: '植物学第三讲',
        transcript: '今天讲木兰科的特征',
      ));
      final hits = await index.searchRaw('木兰科');
      expect(hits.length, 1);
      expect(hits.first.noteId, 'n1');
      expect(hits.first.score, greaterThan(0));
    });

    test('标题命中权重高于原文命中', () async {
      await index.indexDoc(const IndexDoc(
        noteId: 'titleHit',
        title: '木兰科专题',
        transcript: '今天讲别的内容',
      ));
      await index.indexDoc(const IndexDoc(
        noteId: 'bodyHit',
        title: '其他专题',
        transcript: '今天讲木兰科的特征',
      ));
      final hits = await index.searchRaw('木兰科');
      expect(hits.first.noteId, 'titleHit',
          reason: '标题命中应排在原文命中前面');
    });

    test('重复索引同一文档不会产生重复行', () async {
      const doc = IndexDoc(
        noteId: 'n1',
        title: '植物学',
        transcript: '木兰科',
      );
      await index.indexDoc(doc);
      await index.indexDoc(doc);
      // 主键是 (term, note_id, field)，同一 term 只该有一行。
      // 断言单个 term 的行数，而不是拿它和总行数比。
      final one = await db.rawQuery(
        "SELECT COUNT(*) AS c FROM search_terms "
        "WHERE note_id = 'n1' AND term = '木兰'",
      );
      expect((one.first['c'] as num).toInt(), 1,
          reason: '重复索引不该让同一个 term 出现两次');

      // 再确认分数的频次没有被重复累加放大
      final hits = await index.searchRaw('木兰科');
      expect(hits.length, 1);
      expect(hits.first.score, lessThan(10),
          reason: '重复索引不该把分数翻倍（freq 应保持 1）');
    });
  });

  group('索引更新（改笔记后）', () {
    test('内容改掉后旧词搜不到、新词搜得到', () async {
      await index.indexDoc(const IndexDoc(
        noteId: 'n1',
        title: '植物学',
        transcript: '今天讲木兰科',
      ));
      expect((await index.searchRaw('木兰科')).length, 1);

      // 同一篇笔记内容改成另一段
      await index.indexDoc(const IndexDoc(
        noteId: 'n1',
        title: '植物学',
        transcript: '今天讲蔷薇科',
      ));

      expect((await index.searchRaw('木兰科')).isEmpty, isTrue,
          reason: '旧内容不该还能搜到');
      expect((await index.searchRaw('蔷薇科')).length, 1);
    });
  });

  group('索引删除', () {
    test('删除笔记后索引里也没有了', () async {
      await index.indexDoc(const IndexDoc(
        noteId: 'n1',
        title: '植物学',
        transcript: '木兰科',
      ));
      await index.removeDoc('n1');
      expect((await index.searchRaw('木兰科')).isEmpty, isTrue);
    });

    test('删除一条不影响其他笔记', () async {
      await index.indexDoc(const IndexDoc(
          noteId: 'n1', title: 'A', transcript: '木兰科'));
      await index.indexDoc(const IndexDoc(
          noteId: 'n2', title: 'B', transcript: '木兰科'));
      await index.removeDoc('n1');
      final hits = await index.searchRaw('木兰科');
      expect(hits.length, 1);
      expect(hits.first.noteId, 'n2');
    });

    test('清空索引', () async {
      await index.indexDoc(const IndexDoc(
          noteId: 'n1', title: 'A', transcript: '木兰科'));
      await index.clear();
      expect((await index.searchRaw('木兰科')).isEmpty, isTrue);
    });
  });

  group('检索排序', () {
    test('命中 term 更多的笔记排前面', () async {
      await index.indexDoc(const IndexDoc(
        noteId: 'many',
        title: '木兰科与离生心皮',
        transcript: '木兰科木兰科的离生心皮结构',
      ));
      await index.indexDoc(const IndexDoc(
        noteId: 'few',
        title: '杂记',
        transcript: '顺便提了一句木兰科',
      ));
      final hits = await index.searchRaw('木兰科 离生心皮');
      expect(hits.first.noteId, 'many');
    });

    test('无结果时返回空列表而不是报错', () async {
      await index.indexDoc(const IndexDoc(
          noteId: 'n1', title: 'A', transcript: '木兰科'));
      final hits = await index.searchRaw('量子力学');
      expect(hits, isEmpty);
    });

    test('空查询返回空', () async {
      expect(await index.searchRaw(''), isEmpty);
      expect(await index.searchRaw('   '), isEmpty);
    });

    test('limit 生效', () async {
      for (var i = 0; i < 10; i++) {
        await index.indexDoc(IndexDoc(
            noteId: 'n$i', title: '笔记$i', transcript: '木兰科'));
      }
      final hits = await index.searchRaw('木兰科', limit: 3);
      expect(hits.length, 3);
    });
  });

  group('单字查询兜底路径', () {
    test('单字走 LIKE 能命中', () async {
      // 索引里单字也会被切进去（unigram），但短查询走的是另一条路径
      await db.insert('notes', {
        'id': 'n1',
        'title': '植物学',
        'transcript': '叶片的结构',
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'status': 'done',
      });
      final ids = await index.searchShortQuery('叶');
      expect(ids, contains('n1'));
    });

    test('单字兜底不命中时返回空', () async {
      await db.insert('notes', {
        'id': 'n1',
        'title': '植物学',
        'transcript': '茎的结构',
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'status': 'done',
      });
      expect(await index.searchShortQuery('叶'), isEmpty);
    });

    test('单字兜底也能搜标题', () async {
      await db.insert('notes', {
        'id': 'n1',
        'title': '叶的形态',
        'transcript': '无关内容',
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'status': 'done',
      });
      expect(await index.searchShortQuery('叶'), contains('n1'));
    });
  });

  group('中文 bigram 在真实 SQL 里的召回', () {
    test('「离生心皮」能命中原文写成「离心皮」的笔记', () async {
      // 这是 bigram 方案的核心价值：容忍误听/缩写变体
      await index.indexDoc(const IndexDoc(
        noteId: 'n1',
        title: '植物学',
        transcript: '木兰科是离心皮，排列在花托上',
      ));
      final hits = await index.searchRaw('离生心皮');
      expect(hits, isNotEmpty,
          reason: 'bigram「心皮」应该让这个查询命中');
      expect(hits.first.noteId, 'n1');
    });

    test('完全无关的查询不会误命中', () async {
      await index.indexDoc(const IndexDoc(
        noteId: 'n1',
        title: '植物学',
        transcript: '木兰科的离生心皮',
      ));
      expect((await index.searchRaw('建筑制图')).isEmpty, isTrue);
    });
  });

  group('索引规模约束', () {
    test('超长文档不会无限膨胀（受 maxTermsPerField 限制）', () async {
      // 造一段很长但不重复的中文
      final long = List.generate(2000, (i) => '词$i语').join();
      await index.indexDoc(IndexDoc(
        noteId: 'big',
        title: 'long',
        transcript: long,
      ));
      final rows = await db.rawQuery(
          'SELECT COUNT(*) AS c FROM search_terms WHERE note_id = ?', ['big']);
      final count = (rows.first['c'] as num).toInt();
      expect(count, lessThanOrEqualTo(SearchIndex.maxTermsPerField * 3),
          reason: '三个字段各受一次上限约束');
      expect(count, greaterThan(0));
    });
  });
}