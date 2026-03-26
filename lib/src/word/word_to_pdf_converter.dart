import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:xml/xml.dart';

import '../../flutter_preview_file_platform_interface.dart';

class WordToPdfConverter {
  const WordToPdfConverter._();

  static Future<String> convert({
    required String inputPath,
    required String outputPath,
  }) async {
    final file = File(inputPath);
    if (!await file.exists()) {
      throw Exception('The source file is no longer available.');
    }

    final bytes = await file.readAsBytes();
    if (_isOoxmlFile(bytes)) {
      await _convertOoxmlToPdf(bytes: bytes, outputPath: outputPath);
      return outputPath;
    }

    final html = await loadWordHtml(inputPath);
    final result = await FlutterPreviewFilePlatform.instance.convertHtmlToPdf(
      html: html,
      outputPath: outputPath,
    );
    return result ?? outputPath;
  }

  static Future<String> loadWordHtml(String path) async {
    final extension = _queryExtension(path);
    if (extension != 'doc' && extension != 'docx') {
      throw Exception('Only .doc and .docx files support Word to PDF.');
    }

    final file = File(path);
    if (!await file.exists()) {
      throw Exception('The source file is no longer available.');
    }

    final bytes = await file.readAsBytes();
    if (_isOoxmlFile(bytes)) {
      return _buildOoxmlHtml(bytes);
    }

    final result = await FlutterPreviewFilePlatform.instance.loadDocContent(
      path,
    );
    final html = (result?['html'] ?? '').toString();
    if (html.trim().isEmpty) {
      throw Exception('Failed to convert Word file to HTML.');
    }
    return _normalizeHtmlDocument(html);
  }

  static Future<void> _convertOoxmlToPdf({
    required List<int> bytes,
    required String outputPath,
  }) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    final documentFile = archive.findFile('word/document.xml');
    if (documentFile == null) {
      throw Exception('word/document.xml not found');
    }
    final documentXml = XmlDocument.parse(
      utf8.decode(documentFile.content as List<int>),
    );
    final blockList = _buildOoxmlBlockList(documentXml);
    final document = pw.Document();
    final font = await _loadPdfFont();
    final theme = font == null
        ? null
        : pw.ThemeData.withFont(
            base: font,
            bold: font,
            italic: font,
            boldItalic: font,
          );

    document.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(54, 54, 54, 54),
          theme: theme,
        ),
        build: (context) => _buildPdfWidgetList(blockList),
      ),
    );

    final outputFile = File(outputPath);
    await outputFile.parent.create(recursive: true);
    await outputFile.writeAsBytes(await document.save(), flush: true);
  }

  static Future<pw.Font?> _loadPdfFont() async {
    try {
      return await PdfGoogleFonts.notoSansSCRegular();
    } catch (_) {}

    const candidatePathList = <String>['/system/fonts/DroidSansFallback.ttf'];
    for (final path in candidatePathList) {
      final file = File(path);
      if (!await file.exists()) {
        continue;
      }
      try {
        final bytes = await file.readAsBytes();
        return pw.Font.ttf(ByteData.sublistView(bytes));
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  static List<pw.Widget> _buildPdfWidgetList(List<_WordBlock> blockList) {
    final widgetList = <pw.Widget>[];
    for (final block in blockList) {
      switch (block) {
        case _WordPageBreakBlock():
          if (widgetList.isNotEmpty && widgetList.last is! pw.NewPage) {
            widgetList.add(pw.NewPage());
          }
          break;
        case _WordParagraphBlock():
          widgetList.add(_buildParagraphWidget(block));
          break;
        case _WordTableBlock():
          widgetList.add(_buildTableWidget(block));
          break;
      }
    }
    if (widgetList.isEmpty) {
      widgetList.add(pw.SizedBox());
    }
    return widgetList;
  }

  static pw.Widget _buildParagraphWidget(_WordParagraphBlock block) {
    if (block.isEmpty) {
      return pw.SizedBox(height: 14);
    }
    final fontSize = switch (block.headingTag) {
      'h1' => 22.0,
      'h2' => 18.0,
      'h3' => 16.0,
      _ => 12.0,
    };
    final richText = pw.RichText(
      text: pw.TextSpan(
        children: block.spanList.map((span) {
          return pw.TextSpan(
            text: span.text,
            style: pw.TextStyle(
              fontSize: fontSize,
              fontWeight: span.bold ? pw.FontWeight.bold : pw.FontWeight.normal,
              fontStyle: span.italic
                  ? pw.FontStyle.italic
                  : pw.FontStyle.normal,
              decoration: span.underline
                  ? pw.TextDecoration.underline
                  : pw.TextDecoration.none,
              lineSpacing: 2,
            ),
          );
        }).toList(),
      ),
    );
    final content = block.isList
        ? pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Padding(
                padding: const pw.EdgeInsets.only(top: 1),
                child: pw.Text('•', style: pw.TextStyle(fontSize: fontSize)),
              ),
              pw.SizedBox(width: 6),
              pw.Expanded(child: richText),
            ],
          )
        : richText;
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 10),
      child: content,
    );
  }

  static pw.Widget _buildTableWidget(_WordTableBlock block) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(top: 6, bottom: 12),
      child: pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
        defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
        children: block.rowList.map((row) {
          return pw.TableRow(
            children: row.map((cell) {
              return pw.Padding(
                padding: const pw.EdgeInsets.all(6),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: cell.isEmpty
                      ? [pw.SizedBox(height: 14)]
                      : cell.map(_buildTableParagraphWidget).toList(),
                ),
              );
            }).toList(),
          );
        }).toList(),
      ),
    );
  }

  static pw.Widget _buildTableParagraphWidget(_WordParagraphBlock block) {
    if (block.isEmpty) {
      return pw.SizedBox(height: 12);
    }
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 6),
      child: pw.RichText(
        text: pw.TextSpan(
          children: block.spanList.map((span) {
            return pw.TextSpan(
              text: span.text,
              style: pw.TextStyle(
                fontSize: 11,
                fontWeight: span.bold
                    ? pw.FontWeight.bold
                    : pw.FontWeight.normal,
                fontStyle: span.italic
                    ? pw.FontStyle.italic
                    : pw.FontStyle.normal,
                decoration: span.underline
                    ? pw.TextDecoration.underline
                    : pw.TextDecoration.none,
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  static List<_WordBlock> _buildOoxmlBlockList(XmlDocument documentXml) {
    final body = documentXml.findAllElements('w:body').firstOrNull;
    if (body == null) {
      return <_WordBlock>[];
    }
    final blockList = <_WordBlock>[];
    for (final node in body.childElements) {
      if (node.name.qualified == 'w:p') {
        if (_paragraphHasPageBreak(node)) {
          if (blockList.isEmpty || blockList.last is _WordPageBreakBlock) {
            continue;
          }
          blockList.add(const _WordPageBreakBlock());
          continue;
        }
        blockList.add(_parseParagraphBlock(node));
      } else if (node.name.qualified == 'w:tbl') {
        blockList.add(_parseTableBlock(node));
      }
    }
    while (blockList.isNotEmpty && blockList.last is _WordPageBreakBlock) {
      blockList.removeLast();
    }
    return blockList;
  }

  static _WordParagraphBlock _parseParagraphBlock(XmlElement paragraph) {
    final spanList = <_WordSpan>[];
    for (final run in paragraph.findElements('w:r')) {
      final runProp = run.getElement('w:rPr');
      final bold = runProp?.getElement('w:b') != null;
      final italic = runProp?.getElement('w:i') != null;
      final underline = runProp?.getElement('w:u') != null;
      for (final br in run.findElements('w:br')) {
        final type = br.getAttribute('w:type') ?? br.getAttribute('type') ?? '';
        if (type != 'page') {
          spanList.add(
            const _WordSpan(
              text: '\n',
              bold: false,
              italic: false,
              underline: false,
            ),
          );
        }
      }
      final text = run
          .findAllElements('w:t')
          .map((element) => element.innerText)
          .join();
      if (text.isEmpty) {
        continue;
      }
      spanList.add(
        _WordSpan(text: text, bold: bold, italic: italic, underline: underline),
      );
    }
    return _WordParagraphBlock(
      spanList: spanList,
      isList: paragraph.findAllElements('w:numPr').isNotEmpty,
      headingTag: _queryHeadingTag(paragraph),
    );
  }

  static _WordTableBlock _parseTableBlock(XmlElement table) {
    final rowList = <List<List<_WordParagraphBlock>>>[];
    for (final row in table.findElements('w:tr')) {
      final cellList = <List<_WordParagraphBlock>>[];
      for (final cell in row.findElements('w:tc')) {
        final paragraphList = cell
            .findElements('w:p')
            .map(_parseParagraphBlock)
            .toList();
        cellList.add(paragraphList);
      }
      rowList.add(cellList);
    }
    return _WordTableBlock(rowList: rowList);
  }

  static String _buildOoxmlHtml(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final documentFile = archive.findFile('word/document.xml');
    if (documentFile == null) {
      throw Exception('word/document.xml not found');
    }
    final documentXml = XmlDocument.parse(
      utf8.decode(documentFile.content as List<int>),
    );
    final blockList = _buildOoxmlBlockList(documentXml);
    final pageHtmlList = <StringBuffer>[StringBuffer()];

    StringBuffer currentPageBuffer() => pageHtmlList.last;

    for (final block in blockList) {
      switch (block) {
        case _WordPageBreakBlock():
          if (currentPageBuffer().isNotEmpty) {
            pageHtmlList.add(StringBuffer());
          }
          break;
        case _WordParagraphBlock():
          if (block.isEmpty) {
            currentPageBuffer().writeln(
              '<p class="empty-paragraph">&nbsp;</p>',
            );
            continue;
          }
          final richText = block.spanList.map((span) {
            var text = const HtmlEscape(
              HtmlEscapeMode.element,
            ).convert(span.text);
            text = text.replaceAll('\n', '<br/>');
            if (span.bold) {
              text = '<strong>$text</strong>';
            }
            if (span.italic) {
              text = '<em>$text</em>';
            }
            if (span.underline) {
              text = '<u>$text</u>';
            }
            return text;
          }).join();
          if (block.isList) {
            currentPageBuffer().writeln('<ul><li>$richText</li></ul>');
          } else {
            currentPageBuffer().writeln(
              '<${block.headingTag}>$richText</${block.headingTag}>',
            );
          }
        case _WordTableBlock():
          currentPageBuffer().writeln(_buildTableHtml(block));
      }
    }

    return _normalizeHtmlDocument(
      pageHtmlList.map((value) => value.toString()).join('<!--page-break-->'),
    );
  }

  static String _buildTableHtml(_WordTableBlock table) {
    final htmlBuffer = StringBuffer()..writeln('<table>');
    for (final row in table.rowList) {
      htmlBuffer.writeln('<tr>');
      for (final cell in row) {
        final cellBuffer = StringBuffer();
        for (final paragraph in cell) {
          if (paragraph.isEmpty) {
            cellBuffer.writeln('<p class="empty-paragraph">&nbsp;</p>');
            continue;
          }
          final richText = paragraph.spanList.map((span) {
            var text = const HtmlEscape(
              HtmlEscapeMode.element,
            ).convert(span.text);
            text = text.replaceAll('\n', '<br/>');
            if (span.bold) {
              text = '<strong>$text</strong>';
            }
            if (span.italic) {
              text = '<em>$text</em>';
            }
            if (span.underline) {
              text = '<u>$text</u>';
            }
            return text;
          }).join();
          cellBuffer.writeln('<p>$richText</p>');
        }
        htmlBuffer.writeln('<td>${cellBuffer.toString()}</td>');
      }
      htmlBuffer.writeln('</tr>');
    }
    htmlBuffer.writeln('</table>');
    return htmlBuffer.toString();
  }

  static bool _paragraphHasPageBreak(XmlElement paragraph) {
    for (final run in paragraph.findElements('w:r')) {
      for (final br in run.findElements('w:br')) {
        final type = br.getAttribute('w:type') ?? br.getAttribute('type') ?? '';
        if (type == 'page') {
          return true;
        }
      }
    }
    return false;
  }

  static String _queryHeadingTag(XmlElement paragraph) {
    final styleValue = paragraph
        .findAllElements('w:pStyle')
        .map(
          (element) =>
              element.getAttribute('w:val') ??
              element.getAttribute('val') ??
              '',
        )
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    final lowerStyle = styleValue.toLowerCase();
    if (lowerStyle.contains('heading1')) {
      return 'h1';
    }
    if (lowerStyle.contains('heading2')) {
      return 'h2';
    }
    if (lowerStyle.contains('heading3')) {
      return 'h3';
    }
    if (lowerStyle.contains('title')) {
      return 'h2';
    }
    return 'p';
  }

  static String _normalizeHtmlDocument(String html) {
    final content = html.trim();
    if (content.isEmpty) {
      return '''
<html>
<head>
  <meta charset="utf-8" />
  <style>
    html, body { margin: 0; padding: 0; background: #ffffff; }
    body { font-family: sans-serif; color: #222222; }
  </style>
</head>
<body></body>
</html>
''';
    }
    final lower = content.toLowerCase();
    if (lower.startsWith('<html') || lower.startsWith('<!doctype html')) {
      return content;
    }
    final pageList = content
        .split('<!--page-break-->')
        .map((value) => value.trim())
        .toList();
    final pagesBuffer = StringBuffer();
    for (final page in pageList) {
      pagesBuffer.writeln(
        '<div class="doc-page">${page.isEmpty ? '<p class="empty-paragraph">&nbsp;</p>' : page}</div>',
      );
    }
    return '''
<html>
<head>
  <meta charset="utf-8" />
  <style>
    html, body { margin: 0; padding: 0; background: #ffffff; }
    body { font-family: sans-serif; color: #222222; line-height: 1.6; }
    .doc-page {
      width: 595px;
      min-height: 842px;
      box-sizing: border-box;
      padding: 72px 72px 72px 72px;
      overflow: hidden;
      page-break-after: always;
    }
    p { margin: 0 0 12px; }
    .empty-paragraph { min-height: 20px; }
    table { width: 100%; border-collapse: collapse; margin: 12px 0; }
    td, th { border: 1px solid #d0d0d0; padding: 6px 8px; vertical-align: top; }
    ul { margin: 0 0 12px 20px; }
  </style>
</head>
<body>
${pagesBuffer.toString()}
</body>
</html>
''';
  }

  static String _queryExtension(String path) {
    final fileName = path.split('/').last;
    final dotIndex = fileName.lastIndexOf('.');
    if (dotIndex < 0 || dotIndex == fileName.length - 1) {
      return '';
    }
    return fileName.substring(dotIndex + 1).toLowerCase();
  }

  static bool _isOoxmlFile(List<int> bytes) {
    if (bytes.length < 4) {
      return false;
    }
    return bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        bytes[2] == 0x03 &&
        bytes[3] == 0x04;
  }
}

sealed class _WordBlock {
  const _WordBlock();
}

class _WordPageBreakBlock extends _WordBlock {
  const _WordPageBreakBlock();
}

class _WordParagraphBlock extends _WordBlock {
  const _WordParagraphBlock({
    required this.spanList,
    required this.isList,
    required this.headingTag,
  });

  final List<_WordSpan> spanList;
  final bool isList;
  final String headingTag;

  bool get isEmpty => spanList.every((value) => value.text.trim().isEmpty);
}

class _WordTableBlock extends _WordBlock {
  const _WordTableBlock({required this.rowList});

  final List<List<List<_WordParagraphBlock>>> rowList;
}

class _WordSpan {
  const _WordSpan({
    required this.text,
    required this.bold,
    required this.italic,
    required this.underline,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
}
