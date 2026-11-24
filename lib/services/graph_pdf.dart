// lib/services/graph_pdf.dart
// 把思维导图画布导出成单页 PDF（图片内嵌）。
//
// 为什么不引 pdf 包：项目当前 pub 环境加新依赖要跑 pub get，
// 这里只需把一张位图放进 PDF，手写最小 PDF 结构更可控。
// 中文以位图形式嵌入，不依赖字体，手机上能直接打开/转发。
import 'dart:io' show ZLibCodec;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 由一张已渲染的位图生成 A4 单页 PDF。
Future<Uint8List> buildPdfFromImage(ui.Image image) async {
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (bytes == null) {
    throw Exception('导图渲染失败，拿不到位图数据');
  }
  final w = image.width;
  final h = image.height;
  final rgba = bytes.buffer.asUint8List();

  // PDF 图片不支持 alpha 通道：按白底做一次合成，避免透明区域变黑
  final rgb = Uint8List(w * h * 3);
  for (var i = 0, j = 0; i < rgba.length; i += 4, j += 3) {
    // rawRgba 是预乘 alpha：rgb 已乘过 a，白底合成是 r + 255*(1-a)
    final a = rgba[i + 3];
    final inv = 255 - a;
    rgb[j] = (rgba[i] + inv).clamp(0, 255);
    rgb[j + 1] = (rgba[i + 1] + inv).clamp(0, 255);
    rgb[j + 2] = (rgba[i + 2] + inv).clamp(0, 255);
  }
  final compressed = Uint8List.fromList(ZLibCodec(level: 6).encode(rgb));

  const pageW = 595.0; // A4 @72dpi
  const pageH = 842.0;
  const margin = 24.0;
  const maxW = pageW - margin * 2;
  const maxH = pageH - margin * 2;
  final scale = (maxW / w) < (maxH / h) ? maxW / w : maxH / h;
  final drawW = w * scale;
  final drawH = h * scale;
  final x = (pageW - drawW) / 2;
  final y = (pageH - drawH) / 2;
  final content = 'q\n${drawW.toStringAsFixed(2)} 0 0 ${drawH.toStringAsFixed(2)} '
      '${x.toStringAsFixed(2)} ${y.toStringAsFixed(2)} cm\n/Im0 Do\nQ\n';

  final objects = <List<int>>[
    // 1 catalog
    _ascii('<< /Type /Catalog /Pages 2 0 R >>'),
    // 2 pages
    _ascii('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
    // 3 page
    _ascii('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $pageW $pageH] '
        '/Resources << /XObject << /Im0 4 0 R >> >> '
        '/Contents 5 0 R >>'),
    // 4 image
    _streamObject(
      '<< /Type /XObject /Subtype /Image /Width $w /Height $h '
      '/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode '
      '/Length ${compressed.length} >>',
      compressed,
    ),
    // 5 content
    _streamObject('<< /Length ${content.length} >>', _ascii(content)),
  ];

  final out = BytesBuilder();
  out.add(_ascii('%PDF-1.4\n%\u00E2\u00E3\u00CF\u00D3\n'));
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    out.add(_ascii('${i + 1} 0 obj\n'));
    out.add(objects[i]);
    out.add(_ascii('\nendobj\n'));
  }
  final xrefOffset = out.length;
  final xref = StringBuffer('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    xref.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.add(_ascii(xref.toString()));
  out.add(_ascii('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
      'startxref\n$xrefOffset\n%%EOF\n'));
  return out.toBytes();
}

Uint8List _ascii(String s) => Uint8List.fromList(s.codeUnits);

Uint8List _streamObject(String dict, List<int> data) {
  final out = BytesBuilder();
  out.add(_ascii('$dict\nstream\n'));
  out.add(data);
  out.add(_ascii('\nendstream'));
  return out.toBytes();
}