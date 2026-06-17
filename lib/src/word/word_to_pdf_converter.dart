import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:xml/xml.dart';

import '../../flutter_preview_file_platform_interface.dart';

class WordToPdfConverter {
  const WordToPdfConverter._();

  static const defaultCjkFontAssetPath = 'assets/fonts/NotoSansSC-VF.ttf';

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
      await _convertOoxmlToPdf(
        bytes: bytes,
        outputPath: outputPath,
        assetFontBytes: await loadDefaultPdfFontAssetBytes(),
      );
      return outputPath;
    }

    final html = await loadWordHtml(inputPath);
    final result = await FlutterPreviewFilePlatform.instance.convertHtmlToPdf(
      html: html,
      outputPath: outputPath,
    );
    return result ?? outputPath;
  }

  static Future<bool> canConvertInBackground({
    required String inputPath,
  }) async {
    final file = File(inputPath);
    if (!await file.exists()) {
      return false;
    }
    final bytes = await file.readAsBytes();
    return _isOoxmlFile(bytes);
  }

  static Future<String> convertOoxmlFileToPdf({
    required String inputPath,
    required String outputPath,
    Uint8List? assetFontBytes,
  }) async {
    debugPrint(
      'WordToPdf convertOoxmlFileToPdf start input=$inputPath output=$outputPath',
    );
    final file = File(inputPath);
    if (!await file.exists()) {
      throw Exception('The source file is no longer available.');
    }
    final bytes = await file.readAsBytes();
    if (!_isOoxmlFile(bytes)) {
      throw Exception(
        'Current Word file requires native html to pdf conversion.',
      );
    }
    await _convertOoxmlToPdf(
      bytes: bytes,
      outputPath: outputPath,
      assetFontBytes: assetFontBytes ?? await loadDefaultPdfFontAssetBytes(),
    );
    debugPrint('WordToPdf convertOoxmlFileToPdf done output=$outputPath');
    return outputPath;
  }

  static Future<Uint8List?> loadDefaultPdfFontAssetBytes() async {
    try {
      final data = await rootBundle.load(
        'packages/flutter_preview_file/$defaultCjkFontAssetPath',
      );
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {}

    try {
      final data = await rootBundle.load(defaultCjkFontAssetPath);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {}

    return null;
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
    Uint8List? assetFontBytes,
  }) async {
    debugPrint(
      'WordToPdf _convertOoxmlToPdf decode zip start bytes=${bytes.length}',
    );
    final archive = ZipDecoder().decodeBytes(bytes);
    final documentFile = archive.findFile('word/document.xml');
    if (documentFile == null) {
      throw Exception('word/document.xml not found');
    }
    final imageBytesMap = _buildOoxmlImageBytesMap(archive);
    debugPrint(
      'WordToPdf _convertOoxmlToPdf document.xml found size=${(documentFile.content as List<int>).length}',
    );
    final documentXml = XmlDocument.parse(
      utf8.decode(documentFile.content as List<int>),
    );
    final fontNameSet = _buildOoxmlFontNameSet(archive, documentXml);
    debugPrint('WordToPdf _convertOoxmlToPdf xml parsed');
    final blockList = _buildOoxmlBlockList(documentXml, imageBytesMap);
    debugPrint(
      'WordToPdf _convertOoxmlToPdf blockList count=${blockList.length}',
    );
    final document = pw.Document();
    debugPrint('WordToPdf _convertOoxmlToPdf load font start');
    final fontConfig = await _loadPdfFontConfig(
      assetFontBytes: assetFontBytes,
      preferredFontNameSet: fontNameSet,
    );
    debugPrint(
      'WordToPdf _convertOoxmlToPdf load font done fallbackCount=${fontConfig.fontFallback.length}',
    );
    final theme = pw.ThemeData.withFont(
      base: fontConfig.base,
      bold: fontConfig.base,
      italic: fontConfig.base,
      boldItalic: fontConfig.base,
      fontFallback: fontConfig.fontFallback,
    );

    document.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(54, 54, 54, 54),
          theme: theme,
        ),
        build: (context) => _buildPdfWidgetList(blockList, fontConfig),
      ),
    );
    debugPrint('WordToPdf _convertOoxmlToPdf addPage done');

    final outputFile = File(outputPath);
    await outputFile.parent.create(recursive: true);
    debugPrint('WordToPdf _convertOoxmlToPdf save start');
    await outputFile.writeAsBytes(await document.save(), flush: true);
    debugPrint('WordToPdf _convertOoxmlToPdf save done path=$outputPath');
  }

  static Future<_PdfFontConfig> _loadPdfFontConfig({
    required Uint8List? assetFontBytes,
    required Set<String> preferredFontNameSet,
  }) async {
    final fallback = <pw.Font>[];
    final fallbackKeySet = <String>{};

    void addFont(String key, pw.Font font) {
      if (fallbackKeySet.add(key)) {
        fallback.add(font);
      }
    }

    if (assetFontBytes != null && assetFontBytes.isNotEmpty) {
      try {
        addFont(
          defaultCjkFontAssetPath,
          pw.Font.ttf(ByteData.sublistView(assetFontBytes)),
        );
        debugPrint('WordToPdf _loadPdfFontConfig use asset cjk font');
      } catch (_) {}
    }

    for (final entry in _buildLocalPdfFontCandidateList(preferredFontNameSet)) {
      final font = await _loadLocalPdfFont(entry.path);
      if (font != null) {
        addFont(entry.path, font);
      }
    }

    return _PdfFontConfig(
      base: fallback.isEmpty ? pw.Font.helvetica() : fallback.first,
      fontFallback: fallback,
    );
  }

  static Future<pw.Font?> _loadLocalPdfFont(String path) async {
    final lowerPath = path.toLowerCase();
    if (lowerPath.endsWith('.ttc')) {
      debugPrint('WordToPdf _loadLocalPdfFont skip collection font path=$path');
      return null;
    }
    final file = File(path);
    if (!await file.exists()) {
      return null;
    }
    try {
      final bytes = await file.readAsBytes();
      debugPrint('WordToPdf _loadLocalPdfFont use local path=$path');
      return pw.Font.ttf(ByteData.sublistView(bytes));
    } catch (_) {
      return null;
    }
  }

  static List<_FontCandidate> _buildLocalPdfFontCandidateList(
    Set<String> preferredFontNameSet,
  ) {
    const candidateList = <_FontCandidate>[
      _FontCandidate(
        path: '/system/fonts/NotoSansSC-Regular.otf',
        aliases: {'notosanssc', 'noto sans sc', '思源黑体'},
      ),
      _FontCandidate(
        path: '/system/fonts/NotoSansCJK-Regular.ttc',
        aliases: {'notosanscjk', 'noto sans cjk', '思源黑体'},
      ),
      _FontCandidate(
        path: '/system/fonts/DroidSansFallback.ttf',
        aliases: {'droidsansfallback'},
      ),
      _FontCandidate(
        path: '/system/fonts/Roboto-Regular.ttf',
        aliases: {'roboto'},
      ),
      _FontCandidate(
        path: '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
        aliases: {'arial unicode ms', 'arialunicode'},
      ),
      _FontCandidate(
        path: '/System/Library/Fonts/Supplemental/Arial.ttf',
        aliases: {'arial'},
      ),
      _FontCandidate(
        path: '/System/Library/Fonts/Supplemental/Songti.ttc',
        aliases: {'宋体', 'songti', 'simsun'},
      ),
      _FontCandidate(
        path: '/System/Library/Fonts/PingFang.ttc',
        aliases: {'苹方-简', 'pingfang', '-webkit-standard'},
      ),
      _FontCandidate(
        path: '/System/Library/Fonts/Hiragino Sans GB.ttc',
        aliases: {'hiragino sans gb', '冬青黑体'},
      ),
      _FontCandidate(
        path: '/System/Library/Fonts/STHeiti Light.ttc',
        aliases: {'黑体', 'stheiti', 'simhei'},
      ),
      _FontCandidate(
        path: '/System/Library/Fonts/STHeiti Medium.ttc',
        aliases: {'黑体', 'stheiti', 'simhei'},
      ),
      _FontCandidate(
        path: '/Library/Fonts/Arial Unicode.ttf',
        aliases: {'arial unicode ms', 'arialunicode'},
      ),
      _FontCandidate(path: '/Library/Fonts/Arial.ttf', aliases: {'arial'}),
    ];

    bool matchesPreferredFont(_FontCandidate candidate) {
      if (preferredFontNameSet.isEmpty) {
        return false;
      }
      for (final alias in candidate.aliases) {
        if (preferredFontNameSet.contains(_normalizeFontName(alias))) {
          return true;
        }
      }
      return false;
    }

    final preferred = candidateList.where(matchesPreferredFont).toList();
    final remaining = candidateList
        .where((candidate) => !preferred.contains(candidate))
        .toList();
    return <_FontCandidate>[...preferred, ...remaining];
  }

  static Set<String> _buildOoxmlFontNameSet(
    Archive archive,
    XmlDocument documentXml,
  ) {
    final fontNameSet = <String>{};

    void addFontName(String? value) {
      final normalized = _normalizeFontName(value ?? '');
      if (normalized.isNotEmpty) {
        fontNameSet.add(normalized);
      }
    }

    for (final element in documentXml.findAllElements('w:rFonts')) {
      addFontName(element.getAttribute('w:ascii'));
      addFontName(element.getAttribute('ascii'));
      addFontName(element.getAttribute('w:hAnsi'));
      addFontName(element.getAttribute('hAnsi'));
      addFontName(element.getAttribute('w:eastAsia'));
      addFontName(element.getAttribute('eastAsia'));
      addFontName(element.getAttribute('w:cs'));
      addFontName(element.getAttribute('cs'));
    }

    final fontTableFile = archive.findFile('word/fontTable.xml');
    final content = fontTableFile?.content;
    if (content is List<int>) {
      try {
        final fontTableXml = XmlDocument.parse(utf8.decode(content));
        for (final fontElement in fontTableXml.findAllElements('w:font')) {
          final name =
              fontElement.getAttribute('w:name') ??
              fontElement.getAttribute('name');
          final normalizedName = _normalizeFontName(name ?? '');
          if (!fontNameSet.contains(normalizedName)) {
            continue;
          }
          final altNameElement = fontElement.getElement('w:altName');
          addFontName(
            altNameElement?.getAttribute('w:val') ??
                altNameElement?.getAttribute('val'),
          );
        }
      } catch (_) {}
    }

    debugPrint('WordToPdf _buildOoxmlFontNameSet fonts=$fontNameSet');
    return fontNameSet;
  }

  static String _normalizeFontName(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  static List<pw.Widget> _buildPdfWidgetList(
    List<_WordBlock> blockList,
    _PdfFontConfig fontConfig,
  ) {
    final widgetList = <pw.Widget>[];
    for (final block in blockList) {
      switch (block) {
        case _WordPageBreakBlock():
          if (widgetList.isNotEmpty && widgetList.last is! pw.NewPage) {
            widgetList.add(pw.NewPage());
          }
          break;
        case _WordParagraphBlock():
          widgetList.add(_buildParagraphWidget(block, fontConfig));
          break;
        case _WordImageBlock():
          widgetList.add(_buildImageWidget(block));
          break;
        case _WordTableBlock():
          widgetList.add(_buildTableWidget(block, fontConfig));
          break;
      }
    }
    if (widgetList.isEmpty) {
      widgetList.add(pw.SizedBox());
    }
    return widgetList;
  }

  static pw.Widget _buildParagraphWidget(
    _WordParagraphBlock block,
    _PdfFontConfig fontConfig,
  ) {
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
              font: fontConfig.base,
              fontNormal: fontConfig.base,
              fontBold: fontConfig.base,
              fontItalic: fontConfig.base,
              fontBoldItalic: fontConfig.base,
              fontSize: fontSize,
              fontWeight: span.bold ? pw.FontWeight.bold : pw.FontWeight.normal,
              fontStyle: span.italic
                  ? pw.FontStyle.italic
                  : pw.FontStyle.normal,
              decoration: span.underline
                  ? pw.TextDecoration.underline
                  : pw.TextDecoration.none,
              lineSpacing: 2,
              fontFallback: fontConfig.fontFallback,
            ),
          );
        }).toList(),
      ),
    );
    final content = block.isList
        ? pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: <pw.Widget>[
              pw.Padding(
                padding: const pw.EdgeInsets.only(top: 1),
                child: pw.Text(
                  '•',
                  style: pw.TextStyle(
                    font: fontConfig.base,
                    fontNormal: fontConfig.base,
                    fontBold: fontConfig.base,
                    fontItalic: fontConfig.base,
                    fontBoldItalic: fontConfig.base,
                    fontSize: fontSize,
                    fontFallback: fontConfig.fontFallback,
                  ),
                ),
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

  static pw.Widget _buildImageWidget(_WordImageBlock block) {
    final imageProvider = pw.MemoryImage(block.bytes);
    final double width = block.widthPt == null
        ? 220
        : block.widthPt!.clamp(48, 420).toDouble();
    final double? height = block.heightPt?.clamp(32, 420).toDouble();
    return pw.Padding(
      padding: const pw.EdgeInsets.only(top: 4, bottom: 12),
      child: pw.Image(
        imageProvider,
        width: width,
        height: height,
        fit: pw.BoxFit.contain,
      ),
    );
  }

  static pw.Widget _buildTableWidget(
    _WordTableBlock block,
    _PdfFontConfig fontConfig,
  ) {
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
                      ? <pw.Widget>[pw.SizedBox(height: 14)]
                      : cell.map((paragraph) {
                          return _buildTableParagraphWidget(
                            paragraph,
                            fontConfig,
                          );
                        }).toList(),
                ),
              );
            }).toList(),
          );
        }).toList(),
      ),
    );
  }

  static pw.Widget _buildTableParagraphWidget(
    _WordParagraphBlock block,
    _PdfFontConfig fontConfig,
  ) {
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
                font: fontConfig.base,
                fontNormal: fontConfig.base,
                fontBold: fontConfig.base,
                fontItalic: fontConfig.base,
                fontBoldItalic: fontConfig.base,
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
                fontFallback: fontConfig.fontFallback,
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  static List<_WordBlock> _buildOoxmlBlockList(
    XmlDocument documentXml,
    Map<String, Uint8List> imageBytesMap,
  ) {
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
        blockList.addAll(_parseParagraphBlocks(node, imageBytesMap));
      } else if (node.name.qualified == 'w:tbl') {
        blockList.add(_parseTableBlock(node, imageBytesMap));
      }
    }
    while (blockList.isNotEmpty && blockList.last is _WordPageBreakBlock) {
      blockList.removeLast();
    }
    return blockList;
  }

  static List<_WordBlock> _parseParagraphBlocks(
    XmlElement paragraph,
    Map<String, Uint8List> imageBytesMap,
  ) {
    final blockList = <_WordBlock>[];
    final spanList = <_WordSpan>[];
    final bool isList = paragraph.findAllElements('w:numPr').isNotEmpty;
    final String headingTag = _queryHeadingTag(paragraph);

    void flushParagraph() {
      if (spanList.isEmpty) {
        return;
      }
      blockList.add(
        _WordParagraphBlock(
          spanList: List<_WordSpan>.from(spanList),
          isList: isList,
          headingTag: headingTag,
        ),
      );
      spanList.clear();
    }

    for (final run in paragraph.findElements('w:r')) {
      final runProp = run.getElement('w:rPr');
      final bool bold = runProp?.getElement('w:b') != null;
      final bool italic = runProp?.getElement('w:i') != null;
      final bool underline = _queryRunUnderline(runProp);

      for (final br in run.findElements('w:br')) {
        final String type =
            br.getAttribute('w:type') ?? br.getAttribute('type') ?? '';
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

      final String text = run
          .findAllElements('w:t')
          .map((element) => element.innerText)
          .join();
      if (text.isNotEmpty) {
        spanList.add(
          _WordSpan(
            text: text,
            bold: bold,
            italic: italic,
            underline: underline,
          ),
        );
      }

      final _WordImageBlock? imageBlock = _parseRunImageBlock(
        run,
        imageBytesMap,
      );
      if (imageBlock != null) {
        flushParagraph();
        blockList.add(imageBlock);
      }
    }

    flushParagraph();
    if (blockList.isEmpty) {
      blockList.add(
        _WordParagraphBlock(
          spanList: const <_WordSpan>[],
          isList: isList,
          headingTag: headingTag,
        ),
      );
    }
    return blockList;
  }

  static _WordTableBlock _parseTableBlock(
    XmlElement table,
    Map<String, Uint8List> imageBytesMap,
  ) {
    final rowList = <List<List<_WordParagraphBlock>>>[];
    for (final row in table.findElements('w:tr')) {
      final cellList = <List<_WordParagraphBlock>>[];
      for (final cell in row.findElements('w:tc')) {
        final paragraphList = cell.findElements('w:p').expand((paragraph) {
          return _parseParagraphBlocks(
            paragraph,
            imageBytesMap,
          ).whereType<_WordParagraphBlock>();
        }).toList();
        cellList.add(paragraphList);
      }
      rowList.add(cellList);
    }
    return _WordTableBlock(rowList: rowList);
  }

  static bool _queryRunUnderline(XmlElement? runProp) {
    final underlineElement = runProp?.getElement('w:u');
    if (underlineElement == null) {
      return false;
    }
    final value =
        underlineElement.getAttribute('w:val') ??
        underlineElement.getAttribute('val') ??
        '';
    if (value.isEmpty) {
      return true;
    }
    switch (value.toLowerCase()) {
      case '0':
      case 'false':
      case 'none':
        return false;
      default:
        return true;
    }
  }

  static String _buildOoxmlHtml(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final documentFile = archive.findFile('word/document.xml');
    if (documentFile == null) {
      throw Exception('word/document.xml not found');
    }
    final imageBytesMap = _buildOoxmlImageBytesMap(archive);
    final documentXml = XmlDocument.parse(
      utf8.decode(documentFile.content as List<int>),
    );
    final blockList = _buildOoxmlBlockList(documentXml, imageBytesMap);
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
          break;
        case _WordImageBlock():
          continue;
        case _WordTableBlock():
          currentPageBuffer().writeln(_buildTableHtml(block));
          break;
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
        final String type =
            br.getAttribute('w:type') ?? br.getAttribute('type') ?? '';
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

  static Map<String, Uint8List> _buildOoxmlImageBytesMap(Archive archive) {
    final relsFile = archive.findFile('word/_rels/document.xml.rels');
    if (relsFile == null) {
      return const <String, Uint8List>{};
    }
    final relsXml = XmlDocument.parse(
      utf8.decode(relsFile.content as List<int>),
    );
    final imageBytesMap = <String, Uint8List>{};
    for (final relationship in relsXml.findAllElements('Relationship')) {
      final String type = relationship.getAttribute('Type') ?? '';
      if (!type.endsWith('/image')) {
        continue;
      }
      final String relId = relationship.getAttribute('Id') ?? '';
      final String target = relationship.getAttribute('Target') ?? '';
      if (relId.isEmpty || target.isEmpty) {
        continue;
      }
      final ArchiveFile? imageFile = archive.findFile('word/$target');
      final dynamic content = imageFile?.content;
      if (content is List<int>) {
        imageBytesMap[relId] = Uint8List.fromList(content);
      }
    }
    debugPrint(
      'WordToPdf _buildOoxmlImageBytesMap imageCount=${imageBytesMap.length}',
    );
    return imageBytesMap;
  }

  static _WordImageBlock? _parseRunImageBlock(
    XmlElement run,
    Map<String, Uint8List> imageBytesMap,
  ) {
    final XmlElement? drawing = run.getElement('w:drawing');
    if (drawing == null) {
      return null;
    }

    XmlElement? blipElement;
    XmlElement? extentElement;
    for (final element in drawing.descendants.whereType<XmlElement>()) {
      if (blipElement == null && element.name.local == 'blip') {
        blipElement = element;
      }
      if (extentElement == null && element.name.local == 'extent') {
        extentElement = element;
      }
    }
    if (blipElement == null) {
      return null;
    }

    final String relId =
        blipElement.getAttribute('r:embed') ??
        blipElement.getAttribute('embed') ??
        '';
    final Uint8List? bytes = imageBytesMap[relId];
    if (relId.isEmpty || bytes == null) {
      return null;
    }

    return _WordImageBlock(
      bytes: bytes,
      widthPt: _emuToPt(extentElement?.getAttribute('cx')),
      heightPt: _emuToPt(extentElement?.getAttribute('cy')),
    );
  }

  static double? _emuToPt(String? emuText) {
    final int? value = int.tryParse(emuText ?? '');
    if (value == null || value <= 0) {
      return null;
    }
    return value / 12700.0;
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

class _WordImageBlock extends _WordBlock {
  const _WordImageBlock({required this.bytes, this.widthPt, this.heightPt});

  final Uint8List bytes;
  final double? widthPt;
  final double? heightPt;
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

class _PdfFontConfig {
  const _PdfFontConfig({required this.base, required this.fontFallback});

  final pw.Font base;
  final List<pw.Font> fontFallback;
}

class _FontCandidate {
  const _FontCandidate({required this.path, required this.aliases});

  final String path;
  final Set<String> aliases;
}
