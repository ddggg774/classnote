// test/class_mode_test.dart
// 两种记录形态的映射：入口决定语言，语言决定翻译是否启用。

import 'package:flutter_test/flutter_test.dart';

import 'package:classnote/models/class_mode.dart';
import 'package:classnote/models/note.dart';

void main() {
  test('中文模式：zh、不翻译、标题保持原样', () {
    expect(ClassMode.chinese.languageCode, 'zh');
    expect(ClassMode.chinese.translates, isFalse);
    expect(ClassMode.chinese.appBarTitle, '新建课堂记录');
  });

  test('英语课模式：en、启用翻译、独立标题', () {
    expect(ClassMode.english.languageCode, 'en');
    expect(ClassMode.english.translates, isTrue);
    expect(ClassMode.english.appBarTitle, '英语课');
  });

  group('Note 的语言字段', () {
    Note makeNote({String language = 'zh', String? translationJson}) => Note(
          id: 'n1',
          title: '课堂',
          transcript: 'Plants have cell walls.',
          createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          language: language,
          translationJson: translationJson,
        );

    test('默认中文', () {
      expect(makeNote().language, 'zh');
      expect(makeNote().isEnglish, isFalse);
    });

    test('英语课笔记 isEnglish = true', () {
      expect(makeNote(language: 'en').isEnglish, isTrue);
    });

    test('toMap / fromMap 往返，含译文', () {
      final note = makeNote(language: 'en', translationJson: '{"pairs":[]}');
      final back = Note.fromMap(note.toMap());
      expect(back.language, 'en');
      expect(back.isEnglish, isTrue);
      expect(back.translationJson, '{"pairs":[]}');
    });

    test('老库缺列时按中文处理', () {
      final old = Note.fromMap({
        'id': 'old',
        'title': '课堂',
        'transcript': '',
        'created_at': 0,
      });
      expect(old.language, 'zh');
      expect(old.isEnglish, isFalse);
      expect(old.translationJson, isNull);
    });

    test('copyWith(clearTranslation: true) 能清掉译文', () {
      final note = makeNote(language: 'en', translationJson: '{"pairs":[]}');
      final cleared = note.copyWith(clearTranslation: true);
      expect(cleared.translationJson, isNull);
      expect(cleared.language, 'en');
    });
  });
}