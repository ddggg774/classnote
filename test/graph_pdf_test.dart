// test/graph_pdf_test.dart
// PDF 生成的结构性验证：文件头、图片对象、xref 偏移是否自洽。
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:classnote/services/graph_pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('位图能生成结构自洽的单页 PDF', () async {
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 40, 30),
      Paint()..color = const Color(0xFF2E7D32),
    );
    final image = await recorder.endRecording().toImage(40, 30);

    final bytes = await buildPdfFromImage(image);
    image.dispose();

    final text = String.fromCharCodes(bytes);
    expect(text.startsWith('%PDF-1.4'), isTrue);
    expect(text.contains('/Type /XObject'), isTrue);
    expect(text.contains('/Subtype /Image'), isTrue);
    expect(text.contains('/Width 40 /Height 30'), isTrue);
    expect(text.contains('startxref'), isTrue);

    // startxref 指向的偏移必须正好是 xref 表开头
    final idx = text.lastIndexOf('startxref');
    final offset =
        int.parse(text.substring(idx + 'startxref'.length).trim().split('\n').first);
    expect(text.substring(offset, offset + 4), 'xref');

    // 每个 xref 表项都应指向对应对象的起始位置
    final xrefBody = text.substring(offset);
    final entries = RegExp(r'^(\d{10}) (\d{5}) ([nf]) $', multiLine: true)
        .allMatches(xrefBody)
        .toList();
    expect(entries.length, greaterThanOrEqualTo(6)); // 5 对象 + 1 空闲项
    for (var i = 1; i < entries.length; i++) {
      final objOffset = int.parse(entries[i].group(1)!);
      expect(text.substring(objOffset), startsWith('$i 0 obj'));
    }
  });
}
