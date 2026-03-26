import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

class PdfToWordConverter {
  const PdfToWordConverter._();

  static Future<String> extractText({
    required String inputPath,
    List<int>? selectedPageIndexList,
    void Function(double progress)? onProgress,
  }) async {
    final sourceFile = File(inputPath);
    if (!await sourceFile.exists()) {
      throw Exception('The source file is no longer available.');
    }

    final bytes = await sourceFile.readAsBytes();
    final document = PdfDocument(inputBytes: bytes);
    try {
      final extractor = PdfTextExtractor(document);
      final pageTextList = <String>[];
      final targetPageIndexList = _queryTargetPageIndexList(
        pageCount: document.pages.count,
        selectedPageIndexList: selectedPageIndexList,
      );
      if (targetPageIndexList.isEmpty) {
        throw Exception('Please select at least one valid page.');
      }
      onProgress?.call(0);
      for (int i = 0; i < targetPageIndexList.length; i++) {
        final pageIndex = targetPageIndexList[i];
        final rawText = extractor.extractText(
          startPageIndex: pageIndex,
          endPageIndex: pageIndex,
          layoutText: true,
        );
        pageTextList.add(_normalizePageText(rawText));
        onProgress?.call((i + 1) / targetPageIndexList.length);
      }
      return pageTextList.join('\n\n');
    } finally {
      document.dispose();
    }
  }

  static Future<String> convert({
    required String inputPath,
    required String outputPath,
    List<int>? selectedPageIndexList,
    void Function(double progress)? onProgress,
  }) async {
    final text = await extractText(
      inputPath: inputPath,
      selectedPageIndexList: selectedPageIndexList,
      onProgress: onProgress,
    );
    final pageTextList = text.isEmpty ? <String>[''] : text.split('\n\n');
    {
      final docxBytes = _buildDocxBytes(pageTextList);
      final outputFile = File(outputPath);
      await outputFile.parent.create(recursive: true);
      await outputFile.writeAsBytes(docxBytes, flush: true);
      return outputPath;
    }
  }

  static List<int> _queryTargetPageIndexList({
    required int pageCount,
    List<int>? selectedPageIndexList,
  }) {
    if (selectedPageIndexList == null || selectedPageIndexList.isEmpty) {
      return List<int>.generate(pageCount, (index) => index);
    }
    final normalizedPageIndexList = <int>[];
    for (final pageIndex in selectedPageIndexList) {
      if (pageIndex < 0 || pageIndex >= pageCount) {
        continue;
      }
      if (normalizedPageIndexList.contains(pageIndex)) {
        continue;
      }
      normalizedPageIndexList.add(pageIndex);
    }
    return normalizedPageIndexList;
  }

  static String _normalizePageText(String text) {
    return text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\u0000', '')
        .trimRight();
  }

  static List<int> _buildDocxBytes(List<String> pageTextList) {
    final archive = Archive();
    final documentXml = _buildDocumentXml(pageTextList);
    final contentTypesXml = _buildContentTypesXml();
    final relsXml = _buildRootRelsXml();
    final documentRelsXml = _buildDocumentRelsXml();
    final appXml = _buildAppXml(pageTextList.length);
    final coreXml = _buildCoreXml();

    final fileList = <MapEntry<String, String>>[
      MapEntry('[Content_Types].xml', contentTypesXml),
      MapEntry('_rels/.rels', relsXml),
      MapEntry('docProps/app.xml', appXml),
      MapEntry('docProps/core.xml', coreXml),
      MapEntry('word/document.xml', documentXml),
      MapEntry('word/_rels/document.xml.rels', documentRelsXml),
    ];

    for (final entry in fileList) {
      final data = utf8.encode(entry.value);
      archive.addFile(ArchiveFile(entry.key, data.length, data));
    }
    return ZipEncoder().encode(archive) ?? <int>[];
  }

  static String _buildDocumentXml(List<String> pageTextList) {
    final contentBuffer = StringBuffer();
    for (int pageIndex = 0; pageIndex < pageTextList.length; pageIndex++) {
      final pageText = pageTextList[pageIndex];
      final lineList = pageText.isEmpty ? <String>[''] : pageText.split('\n');
      for (final line in lineList) {
        if (line.isEmpty) {
          contentBuffer.write('<w:p/>');
          continue;
        }
        final escapedText = _escapeXmlText(line);
        contentBuffer.write(
          '<w:p><w:r><w:t xml:space="preserve">$escapedText</w:t></w:r></w:p>',
        );
      }
      if (pageIndex != pageTextList.length - 1) {
        contentBuffer.write(
          '<w:p><w:r><w:br w:type="page"/></w:r></w:p>',
        );
      }
    }

    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:wpc="http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas"
 xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
 xmlns:o="urn:schemas-microsoft-com:office:office"
 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
 xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math"
 xmlns:v="urn:schemas-microsoft-com:vml"
 xmlns:wp14="http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing"
 xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
 xmlns:w10="urn:schemas-microsoft-com:office:word"
 xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
 xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml"
 xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml"
 xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"
 xmlns:wpi="http://schemas.microsoft.com/office/word/2010/wordprocessingInk"
 xmlns:wne="http://schemas.microsoft.com/office/word/2006/wordml"
 xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
 mc:Ignorable="w14 w15 wp14">
  <w:body>
    ${contentBuffer.toString()}
    <w:sectPr>
      <w:pgSz w:w="11906" w:h="16838"/>
      <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/>
    </w:sectPr>
  </w:body>
</w:document>''';
  }

  static String _buildContentTypesXml() {
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>''';
  }

  static String _buildRootRelsXml() {
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
</Relationships>''';
  }

  static String _buildDocumentRelsXml() {
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>''';
  }

  static String _buildAppXml(int pageCount) {
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"
 xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
  <Application>b03pdf</Application>
  <Pages>$pageCount</Pages>
</Properties>''';
  }

  static String _buildCoreXml() {
    final now = DateTime.now().toUtc().toIso8601String();
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
 xmlns:dc="http://purl.org/dc/elements/1.1/"
 xmlns:dcterms="http://purl.org/dc/terms/"
 xmlns:dcmitype="http://purl.org/dc/dcmitype/"
 xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <dc:title>PDF to Word</dc:title>
  <dc:creator>b03pdf</dc:creator>
  <cp:lastModifiedBy>b03pdf</cp:lastModifiedBy>
  <dcterms:created xsi:type="dcterms:W3CDTF">$now</dcterms:created>
  <dcterms:modified xsi:type="dcterms:W3CDTF">$now</dcterms:modified>
</cp:coreProperties>''';
  }

  static String _escapeXmlText(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}
