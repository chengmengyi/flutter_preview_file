import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:xml/xml.dart';

import '../../flutter_preview_file.dart';

class WordFileController extends ChangeNotifier {
  WordFileController({required this.filePath});

  final String filePath;
  final TextEditingController textEditingController = TextEditingController();
  final FocusNode textFocusNode = FocusNode();

  bool fileExists = false;
  bool loading = true;
  bool saving = false;
  bool isEditing = false;
  bool preparingHtmlEditor = false;
  bool preparingHtmlPreview = false;
  String errorText = '';
  String htmlText = '';
  String plainText = '';
  String loadedFileType = '';
  String originalHtmlDocument = '';
  WebViewController? htmlEditorController;
  WebViewController? htmlPreviewController;

  bool _initialized = false;

  bool get isHtmlEditable => loadedFileType == 'html';
  bool get isOoxmlImageEditable =>
      loadedFileType == 'ooxml' && htmlText.contains('<img');
  bool get usesHtmlEditor => isHtmlEditable || isOoxmlImageEditable;
  bool get usesHtmlPreview =>
      loadedFileType == 'html' || htmlText.contains('<img');

  Future<void> initialize({bool force = false}) async {
    if (_initialized && !force) {
      return;
    }
    _initialized = true;
    fileExists = filePath.isNotEmpty && File(filePath).existsSync();

    if (!fileExists) {
      loading = false;
      errorText = 'The source file is no longer available.';
      notifyListeners();
      return;
    }

    loading = true;
    saving = false;
    isEditing = false;
    errorText = '';
    htmlText = '';
    plainText = '';
    loadedFileType = '';
    originalHtmlDocument = '';
    htmlEditorController = null;
    htmlPreviewController = null;
    notifyListeners();

    try {
      final loadedContent = await _loadWordContent();
      htmlText = loadedContent.html;
      plainText = loadedContent.text;
      loadedFileType = loadedContent.type;
      originalHtmlDocument = loadedContent.html;
      if (usesHtmlPreview) {
        await _prepareHtmlPreview();
      }
      textEditingController.text = plainText;
      if (htmlText.trim().isEmpty) {
        errorText = 'The document content could not be parsed.';
      }
    } on PlatformException catch (error) {
      errorText = error.message?.isNotEmpty == true
          ? error.message!
          : 'Failed to convert Word file to HTML.';
    } catch (error) {
      errorText = error.toString().replaceFirst('Exception: ', '');
      if (errorText.isEmpty) {
        errorText = 'Failed to convert Word file to HTML.';
      }
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> reload() => initialize(force: true);

  Future<void> enterEditMode() async {
    if (loading || saving || errorText.isNotEmpty || isEditing) {
      return;
    }
    if (usesHtmlEditor) {
      await _prepareHtmlEditor();
    }
    isEditing = true;
    textEditingController.text = plainText;
    notifyListeners();
    if (!usesHtmlEditor) {
      Future<void>.delayed(const Duration(milliseconds: 100), () async {
        if (textFocusNode.canRequestFocus) {
          textFocusNode.requestFocus();
        }
      });
    }
  }

  Future<void> cancelEditing() async {
    if (!isEditing || saving) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    isEditing = false;
    textEditingController.text = plainText;
    htmlEditorController = null;
    notifyListeners();
  }

  Future<void> save() async {
    if (!isEditing || saving) {
      return;
    }
    saving = true;
    notifyListeners();
    try {
      final newText = textEditingController.text;
      if (isHtmlEditable) {
        await _saveHtmlDocument();
      } else if (isOoxmlImageEditable) {
        await _saveOoxmlHtmlDocument();
      } else {
        final file = File(filePath);
        final extension = _queryExtension(filePath);
        if (extension == 'txt') {
          await file.writeAsString(newText, flush: true);
          loadedFileType = 'txt';
        } else {
          final bytes = await file.readAsBytes();
          if (_isOoxmlFile(bytes)) {
            await _saveOoxmlTextContent(bytes, newText);
            loadedFileType = 'ooxml';
          } else {
            await FlutterPreviewFile.saveDocTextContent(
              path: filePath,
              text: newText,
            );
          }
        }
        plainText = newText;
        htmlText = _buildPlainTextPreviewHtml(newText);
      }
      isEditing = false;
      htmlEditorController = null;
      FocusManager.instance.primaryFocus?.unfocus();
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  Future<void> _prepareHtmlEditor() async {
    preparingHtmlEditor = true;
    notifyListeners();
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white);
    await controller.loadHtmlString(
      _buildEditableHtmlDocument(originalHtmlDocument),
    );
    htmlEditorController = controller;
    preparingHtmlEditor = false;
    notifyListeners();
  }

  Future<void> _prepareHtmlPreview() async {
    preparingHtmlPreview = true;
    notifyListeners();
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white);
    await controller.loadHtmlString(originalHtmlDocument);
    htmlPreviewController = controller;
    preparingHtmlPreview = false;
    notifyListeners();
  }

  Future<void> _saveHtmlDocument() async {
    final controller = htmlEditorController;
    if (controller == null) {
      throw Exception('HTML editor is not ready.');
    }
    final result = await controller.runJavaScriptReturningResult(
      'btoa(unescape(encodeURIComponent(document.body.innerHTML)))',
    );
    final innerHtml = _decodeHtmlEditorResult(result);
    final savedHtml = _replaceHtmlBody(originalHtmlDocument, innerHtml);
    await File(filePath).writeAsString(savedHtml, flush: true);
    originalHtmlDocument = savedHtml;
    htmlText = savedHtml;
    plainText = _stripHtmlTags(savedHtml);
    textEditingController.text = plainText;
    await _prepareHtmlPreview();
  }

  Future<void> _saveOoxmlHtmlDocument() async {
    final controller = htmlEditorController;
    if (controller == null) {
      throw Exception('HTML editor is not ready.');
    }
    final blocks = await _queryEditedOoxmlBlocks(controller);
    final bytes = await File(filePath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final documentIndex = archive.files.indexWhere(
      (file) => file.name == 'word/document.xml',
    );
    if (documentIndex < 0) {
      throw Exception('word/document.xml not found');
    }
    final oldFile = archive[documentIndex];
    final oldXml = XmlDocument.parse(utf8.decode(oldFile.content as List<int>));
    final xmlText = _buildOoxmlDocumentXmlFromBlocks(oldXml, blocks);
    final xmlBytes = utf8.encode(xmlText);
    archive[documentIndex] =
        ArchiveFile(oldFile.name, xmlBytes.length, xmlBytes)
          ..compress = oldFile.compress
          ..mode = oldFile.mode
          ..lastModTime = oldFile.lastModTime;
    final encodedBytes = ZipEncoder().encode(archive);
    if (encodedBytes == null) {
      throw Exception('Failed to save docx content.');
    }
    await File(filePath).writeAsBytes(encodedBytes, flush: true);

    final loadedContent = await _loadWordContent();
    htmlText = loadedContent.html;
    plainText = loadedContent.text;
    loadedFileType = loadedContent.type;
    originalHtmlDocument = loadedContent.html;
    textEditingController.text = plainText;
    await _prepareHtmlPreview();
  }

  Future<List<Map<String, dynamic>>> _queryEditedOoxmlBlocks(
    WebViewController controller,
  ) async {
    final result = await controller.runJavaScriptReturningResult(r'''
(function () {
  function pushText(items, text) {
    if (!text) {
      return;
    }
    var normalized = text.replace(/\u00a0/g, ' ');
    if (
      normalized.indexOf('img[data-docx-embed-id]') >= 0 ||
      normalized.indexOf("document.addEventListener('click'") >= 0 ||
      normalized.indexOf('docx-selected-image') >= 0
    ) {
      return;
    }
    if (normalized.trim().length > 0) {
      items.push({ type: 'text', text: normalized });
    }
  }

  function readInline(node, items) {
    if (node.nodeType === Node.TEXT_NODE) {
      pushText(items, node.nodeValue || '');
      return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) {
      return;
    }
    var tagName = node.tagName;
    if (tagName === 'STYLE' || tagName === 'SCRIPT') {
      return;
    }
    if (tagName === 'IMG') {
      var embedId = node.getAttribute('data-docx-embed-id') || '';
      if (embedId) {
        items.push({ type: 'image', embedId: embedId });
      }
      return;
    }
    if (tagName === 'BR') {
      items.push({ type: 'break' });
      return;
    }
    Array.prototype.forEach.call(node.childNodes, function (child) {
      readInline(child, items);
    });
  }

  function readParagraph(node) {
    var items = [];
    readInline(node, items);
    if (!items.length) {
      return null;
    }
    return {
      type: 'paragraph',
      tag: (node.tagName || 'p').toLowerCase(),
      items: items
    };
  }

  function readTable(node) {
    var rows = [];
    Array.prototype.forEach.call(node.querySelectorAll('tr'), function (row) {
      var cells = [];
      Array.prototype.forEach.call(row.children, function (cell) {
        if (cell.tagName !== 'TD' && cell.tagName !== 'TH') {
          return;
        }
        var items = [];
        readInline(cell, items);
        cells.push({ items: items });
      });
      if (cells.length) {
        rows.push({ cells: cells });
      }
    });
    if (!rows.length) {
      return null;
    }
    return { type: 'table', rows: rows };
  }

  function appendNode(node, blocks) {
    if (node.nodeType === Node.TEXT_NODE) {
      var items = [];
      pushText(items, node.nodeValue || '');
      if (items.length) {
        blocks.push({ type: 'paragraph', tag: 'p', items: items });
      }
      return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) {
      return;
    }
    if (node.tagName === 'TABLE') {
      var table = readTable(node);
      if (table) {
        blocks.push(table);
      }
      return;
    }
    if (node.tagName === 'UL' || node.tagName === 'OL') {
      Array.prototype.forEach.call(node.children, function (child) {
        var paragraph = readParagraph(child);
        if (paragraph) {
          paragraph.tag = 'li';
          blocks.push(paragraph);
        }
      });
      return;
    }
    var paragraph = readParagraph(node);
    if (paragraph) {
      blocks.push(paragraph);
    }
  }

  var blocks = [];
  Array.prototype.forEach.call(document.body.childNodes, function (node) {
    appendNode(node, blocks);
  });
  return btoa(unescape(encodeURIComponent(JSON.stringify(blocks))));
})()
''');
    final decoded = _decodeHtmlEditorResult(result);
    final list = jsonDecode(decoded) as List<dynamic>;
    return list
        .whereType<Map<dynamic, dynamic>>()
        .map(
          (item) => item.map(
            (key, value) => MapEntry(key.toString(), value),
          ),
        )
        .toList(growable: false);
  }

  Future<_WordLoadedContent> _loadWordContent() async {
    final extension = _queryExtension(filePath);
    if (extension != 'docx' && extension != 'doc' && extension != 'txt') {
      throw Exception(
        'Only .docx, .doc, and .txt files support in-app Word preview.',
      );
    }

    if (extension == 'txt') {
      final text = await File(filePath).readAsString();
      return _WordLoadedContent(
        html: _buildPlainTextPreviewHtml(text),
        text: text,
        type: 'txt',
      );
    }

    final bytes = await File(filePath).readAsBytes();
    if (_isOoxmlFile(bytes)) {
      final archive = ZipDecoder().decodeBytes(bytes);
      final documentFile = archive.findFile('word/document.xml');
      if (documentFile == null) {
        throw Exception('word/document.xml not found');
      }
      final documentXml = XmlDocument.parse(
        utf8.decode(documentFile.content as List<int>),
      );
      return _buildOoxmlContent(
        documentXml,
        archive,
        _buildDocumentRelationshipMap(archive),
      );
    }

    final result = await FlutterPreviewFile.loadDocContent(filePath);
    final html = (result?['html'] ?? '').toString();
    final text = (result?['text'] ?? '').toString();
    final type = (result?['type'] ?? '').toString();
    return _WordLoadedContent(
      html: html.isEmpty ? _buildPlainTextPreviewHtml(text) : html,
      text: text,
      type: type,
    );
  }

  _WordLoadedContent _buildOoxmlContent(
    XmlDocument documentXml,
    Archive archive,
    Map<String, String> relationshipMap,
  ) {
    final body = documentXml.findAllElements('w:body').firstOrNull;
    if (body == null) {
      return const _WordLoadedContent(html: '', text: '', type: 'ooxml');
    }
    final htmlBuffer = StringBuffer()..writeln('<html><body>');
    final textBuffer = StringBuffer();
    var listOpened = false;

    for (final node in body.childElements) {
      if (node.name.qualified == 'w:p') {
        final paragraphContent = _parseParagraphContent(
          node,
          archive,
          relationshipMap,
        );
        final isList = node.findAllElements('w:numPr').isNotEmpty;
        if (paragraphContent.html.isEmpty && paragraphContent.text.isEmpty) {
          continue;
        }
        if (isList && !listOpened) {
          htmlBuffer.writeln('<ul>');
          listOpened = true;
        } else if (!isList && listOpened) {
          htmlBuffer.writeln('</ul>');
          listOpened = false;
        }
        if (isList) {
          htmlBuffer.writeln('<li>${paragraphContent.html}</li>');
        } else {
          final headingTag = _queryHeadingTag(node);
          htmlBuffer.writeln(
            '<$headingTag>${paragraphContent.html}</$headingTag>',
          );
        }
        if (textBuffer.isNotEmpty) {
          textBuffer.writeln();
        }
        textBuffer.write(paragraphContent.text);
      } else if (node.name.qualified == 'w:tbl') {
        final tableContent = _parseTableContent(node, archive, relationshipMap);
        if (listOpened) {
          htmlBuffer.writeln('</ul>');
          listOpened = false;
        }
        if (tableContent.html.isNotEmpty) {
          htmlBuffer.writeln(tableContent.html);
        }
        if (tableContent.text.isNotEmpty) {
          if (textBuffer.isNotEmpty) {
            textBuffer.writeln();
            textBuffer.writeln();
          }
          textBuffer.write(tableContent.text);
        }
      }
    }

    if (listOpened) {
      htmlBuffer.writeln('</ul>');
    }
    htmlBuffer.writeln('</body></html>');
    return _WordLoadedContent(
      html: htmlBuffer.toString(),
      text: textBuffer.toString(),
      type: 'ooxml',
    );
  }

  _WordNodeContent _parseParagraphContent(
    XmlElement paragraph,
    Archive archive,
    Map<String, String> relationshipMap,
  ) {
    final htmlBuffer = StringBuffer();
    final textBuffer = StringBuffer();
    for (final run in paragraph.findElements('w:r')) {
      final imageHtml = _buildImageHtml(run, archive, relationshipMap);
      if (imageHtml.isNotEmpty) {
        htmlBuffer.write(imageHtml);
        if (textBuffer.isNotEmpty) {
          textBuffer.write(' ');
        }
        textBuffer.write('[图片]');
      }
      final text = run
          .findAllElements('w:t')
          .map((element) => element.innerText)
          .join();
      if (text.isEmpty) {
        if (run.findElements('w:br').isNotEmpty) {
          htmlBuffer.write('<br/>');
          textBuffer.writeln();
        }
        continue;
      }
      textBuffer.write(text);
      String runHtml = const HtmlEscape(HtmlEscapeMode.element).convert(text);
      final runProp = run.getElement('w:rPr');
      if (runProp != null) {
        if (runProp.getElement('w:b') != null) {
          runHtml = '<strong>$runHtml</strong>';
        }
        if (runProp.getElement('w:i') != null) {
          runHtml = '<em>$runHtml</em>';
        }
        if (runProp.getElement('w:u') != null) {
          runHtml = '<u>$runHtml</u>';
        }
      }
      htmlBuffer.write(runHtml);
    }
    return _WordNodeContent(
      html: htmlBuffer.toString().trim(),
      text: textBuffer.toString().trim(),
    );
  }

  _WordNodeContent _parseTableContent(
    XmlElement table,
    Archive archive,
    Map<String, String> relationshipMap,
  ) {
    final htmlBuffer = StringBuffer();
    final textBuffer = StringBuffer();
    htmlBuffer.writeln('<table border="1" cellspacing="0" cellpadding="6">');
    for (final row in table.findElements('w:tr')) {
      htmlBuffer.writeln('<tr>');
      final rowTexts = <String>[];
      for (final cell in row.findElements('w:tc')) {
        final cellContent = StringBuffer();
        final cellTexts = <String>[];
        for (final paragraph in cell.findElements('w:p')) {
          final paragraphContent = _parseParagraphContent(
            paragraph,
            archive,
            relationshipMap,
          );
          if (paragraphContent.html.isNotEmpty) {
            cellContent.writeln('<p>${paragraphContent.html}</p>');
          }
          if (paragraphContent.text.isNotEmpty) {
            cellTexts.add(paragraphContent.text);
          }
        }
        htmlBuffer.writeln('<td>${cellContent.toString()}</td>');
        rowTexts.add(cellTexts.join(' '));
      }
      htmlBuffer.writeln('</tr>');
      textBuffer.writeln(rowTexts.join('\t'));
    }
    htmlBuffer.writeln('</table>');
    return _WordNodeContent(
      html: htmlBuffer.toString(),
      text: textBuffer.toString().trim(),
    );
  }

  String _queryHeadingTag(XmlElement paragraph) {
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

  Map<String, String> _buildDocumentRelationshipMap(Archive archive) {
    final relationshipFile = archive.findFile('word/_rels/document.xml.rels');
    if (relationshipFile == null) {
      return const {};
    }
    final relationshipsXml = XmlDocument.parse(
      utf8.decode(relationshipFile.content as List<int>),
    );
    final relationshipMap = <String, String>{};
    for (final relation in relationshipsXml.findAllElements('Relationship')) {
      final id = relation.getAttribute('Id') ?? '';
      final target = relation.getAttribute('Target') ?? '';
      if (id.isEmpty || target.isEmpty) {
        continue;
      }
      relationshipMap[id] = target;
    }
    return relationshipMap;
  }

  String _buildImageHtml(
    XmlElement run,
    Archive archive,
    Map<String, String> relationshipMap,
  ) {
    final imageHtmlList = <String>[];

    for (final drawing in run.findAllElements('w:drawing')) {
      final embedId = _findImageEmbedId(drawing);
      final imageHtml = _buildEmbeddedImageHtml(
        embedId: embedId,
        archive: archive,
        relationshipMap: relationshipMap,
      );
      if (imageHtml.isNotEmpty) {
        imageHtmlList.add(imageHtml);
      }
    }

    for (final imageData in run.findAllElements('v:imagedata')) {
      final embedId =
          imageData.getAttribute('r:id') ??
          imageData.getAttribute(
            'id',
            namespace: 'http://schemas.openxmlformats.org/officeDocument/2006/relationships',
          ) ??
          '';
      final imageHtml = _buildEmbeddedImageHtml(
        embedId: embedId,
        archive: archive,
        relationshipMap: relationshipMap,
      );
      if (imageHtml.isNotEmpty) {
        imageHtmlList.add(imageHtml);
      }
    }

    return imageHtmlList.join();
  }

  String _findImageEmbedId(XmlElement drawing) {
    for (final blip in drawing.findAllElements('a:blip')) {
      final embedId =
          blip.getAttribute('r:embed') ??
          blip.getAttribute(
            'embed',
            namespace: 'http://schemas.openxmlformats.org/officeDocument/2006/relationships',
          ) ??
          '';
      if (embedId.isNotEmpty) {
        return embedId;
      }
    }
    return '';
  }

  String _buildEmbeddedImageHtml({
    required String embedId,
    required Archive archive,
    required Map<String, String> relationshipMap,
  }) {
    if (embedId.isEmpty) {
      return '';
    }
    final target = relationshipMap[embedId];
    if (target == null || target.isEmpty) {
      return '';
    }
    final normalizedPath = _normalizeWordTargetPath(target);
    final imageFile = archive.findFile(normalizedPath);
    final imageBytes = imageFile?.content;
    if (imageBytes is! List<int> || imageBytes.isEmpty) {
      return '';
    }
    final mimeType = _queryImageMimeType(normalizedPath);
    final base64Image = base64Encode(imageBytes);
    final escapedEmbedId = _escapeXmlAttribute(embedId);
    return '<img src="data:$mimeType;base64,$base64Image" '
        'data-docx-embed-id="$escapedEmbedId" '
        'contenteditable="false" '
        'style="max-width: 100%; height: auto; vertical-align: middle;"/>';
  }

  String _normalizeWordTargetPath(String target) {
    final normalized = target.replaceAll('\\', '/');
    if (normalized.startsWith('/')) {
      return normalized.substring(1);
    }
    if (normalized.startsWith('word/')) {
      return normalized;
    }
    return 'word/$normalized';
  }

  String _queryImageMimeType(String path) {
    final extension = _queryExtension(path);
    switch (extension) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'bmp':
        return 'image/bmp';
      case 'webp':
        return 'image/webp';
      case 'svg':
        return 'image/svg+xml';
      case 'tif':
      case 'tiff':
        return 'image/tiff';
      default:
        return 'application/octet-stream';
    }
  }

  Future<void> _saveOoxmlTextContent(List<int> bytes, String text) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    final documentIndex = archive.files.indexWhere(
      (file) => file.name == 'word/document.xml',
    );
    if (documentIndex < 0) {
      throw Exception('word/document.xml not found');
    }
    final oldFile = archive[documentIndex];
    final oldXml = XmlDocument.parse(utf8.decode(oldFile.content as List<int>));
    final xmlText = _buildOoxmlDocumentXml(oldXml, text);
    final xmlBytes = utf8.encode(xmlText);
    archive[documentIndex] =
        ArchiveFile(oldFile.name, xmlBytes.length, xmlBytes)
          ..compress = oldFile.compress
          ..mode = oldFile.mode
          ..lastModTime = oldFile.lastModTime;
    final encodedBytes = ZipEncoder().encode(archive);
    if (encodedBytes == null) {
      throw Exception('Failed to save docx content.');
    }
    await File(filePath).writeAsBytes(encodedBytes, flush: true);
  }

  String _buildOoxmlDocumentXmlFromBlocks(
    XmlDocument oldXml,
    List<Map<String, dynamic>> blocks,
  ) {
    final root = oldXml.rootElement;
    final body = root.findElements('w:body').firstOrNull;
    if (body == null) {
      throw Exception('w:body not found');
    }
    final sectPr =
        body.findElements('w:sectPr').firstOrNull?.toXmlString() ?? '';
    final imageRunMap = _buildImageRunXmlMap(oldXml);
    final contentBuffer = StringBuffer();
    for (final block in blocks) {
      final type = block['type']?.toString() ?? '';
      if (type == 'table') {
        contentBuffer.write(_buildOoxmlTableXml(block, imageRunMap));
      } else {
        contentBuffer.write(_buildOoxmlParagraphXml(block, imageRunMap));
      }
    }
    if (contentBuffer.isEmpty) {
      contentBuffer.write('<w:p/>');
    }

    final attributes = root.attributes
        .map(
          (attribute) =>
              '${attribute.name.qualified}="${_escapeXmlAttribute(attribute.value)}"',
        )
        .join(' ');
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<${root.name.qualified} $attributes>'
        '<w:body>${contentBuffer.toString()}$sectPr</w:body>'
        '</${root.name.qualified}>';
  }

  Map<String, String> _buildImageRunXmlMap(XmlDocument oldXml) {
    final imageRunMap = <String, String>{};
    for (final run in oldXml.findAllElements('w:r')) {
      for (final drawing in run.findAllElements('w:drawing')) {
        final embedId = _findImageEmbedId(drawing);
        if (embedId.isNotEmpty) {
          imageRunMap[embedId] = run.toXmlString();
        }
      }
      for (final imageData in run.findAllElements('v:imagedata')) {
        final embedId =
            imageData.getAttribute('r:id') ??
            imageData.getAttribute(
              'id',
              namespace: 'http://schemas.openxmlformats.org/officeDocument/2006/relationships',
            ) ??
            '';
        if (embedId.isNotEmpty) {
          imageRunMap[embedId] = run.toXmlString();
        }
      }
    }
    return imageRunMap;
  }

  String _buildOoxmlParagraphXml(
    Map<String, dynamic> block,
    Map<String, String> imageRunMap,
  ) {
    final runXml = _buildOoxmlRunXmlList(
      _queryMapList(block['items']),
      imageRunMap,
    );
    if (runXml.isEmpty) {
      return '<w:p/>';
    }
    return '<w:p>$runXml</w:p>';
  }

  String _buildOoxmlTableXml(
    Map<String, dynamic> block,
    Map<String, String> imageRunMap,
  ) {
    final buffer = StringBuffer()..write('<w:tbl>');
    for (final row in _queryMapList(block['rows'])) {
      buffer.write('<w:tr>');
      for (final cell in _queryMapList(row['cells'])) {
        final runXml = _buildOoxmlRunXmlList(
          _queryMapList(cell['items']),
          imageRunMap,
        );
        buffer.write('<w:tc><w:p>$runXml</w:p></w:tc>');
      }
      buffer.write('</w:tr>');
    }
    buffer.write('</w:tbl>');
    return buffer.toString();
  }

  String _buildOoxmlRunXmlList(
    List<Map<String, dynamic>> items,
    Map<String, String> imageRunMap,
  ) {
    final buffer = StringBuffer();
    for (final item in items) {
      final type = item['type']?.toString() ?? '';
      if (type == 'image') {
        final embedId = item['embedId']?.toString() ?? '';
        final imageRunXml = imageRunMap[embedId];
        if (imageRunXml != null && imageRunXml.isNotEmpty) {
          buffer.write(imageRunXml);
        }
      } else if (type == 'break') {
        buffer.write('<w:r><w:br/></w:r>');
      } else if (type == 'text') {
        final text = _sanitizeEditorArtifactText(item['text']?.toString() ?? '');
        if (text.isNotEmpty) {
          final escapedText = const HtmlEscape(
            HtmlEscapeMode.element,
          ).convert(text);
          buffer.write(
            '<w:r><w:t xml:space="preserve">$escapedText</w:t></w:r>',
          );
        }
      }
    }
    return buffer.toString();
  }

  String _sanitizeEditorArtifactText(String text) {
    if (text.isEmpty) {
      return '';
    }
    final normalized = text
        .replaceAll(RegExp(r'img\[data-docx-embed-id\][\s\S]*?docx-selected-image\s*\{[\s\S]*?\}'), '')
        .replaceAll(
          RegExp(r"document\.addEventListener\('click'[\s\S]*?image\.remove\(\);\s*\}\);"),
          '',
        )
        .trim();
    return normalized;
  }

  List<Map<String, dynamic>> _queryMapList(Object? value) {
    if (value is! List) {
      return const [];
    }
    return value
        .whereType<Map<dynamic, dynamic>>()
        .map(
          (item) => item.map(
            (key, value) => MapEntry(key.toString(), value),
          ),
        )
        .toList();
  }

  String _buildOoxmlDocumentXml(XmlDocument oldXml, String text) {
    final root = oldXml.rootElement;
    final body = root.findElements('w:body').firstOrNull;
    if (body == null) {
      throw Exception('w:body not found');
    }
    final sectPr =
        body.findElements('w:sectPr').firstOrNull?.toXmlString() ?? '';
    final paragraphs = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    final contentBuffer = StringBuffer();
    for (final line in paragraphs) {
      if (line.isEmpty) {
        contentBuffer.write('<w:p/>');
        continue;
      }
      final escapedText = const HtmlEscape(
        HtmlEscapeMode.element,
      ).convert(line);
      contentBuffer.write(
        '<w:p><w:r><w:t xml:space="preserve">$escapedText</w:t></w:r></w:p>',
      );
    }

    final attributes = root.attributes
        .map(
          (attribute) =>
              '${attribute.name.qualified}="${_escapeXmlAttribute(attribute.value)}"',
        )
        .join(' ');
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<${root.name.qualified} $attributes>'
        '<w:body>${contentBuffer.toString()}$sectPr</w:body>'
        '</${root.name.qualified}>';
  }

  String _escapeXmlAttribute(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('"', '&quot;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }

  String _buildPlainTextPreviewHtml(String text) {
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalized.split('\n');
    final buffer = StringBuffer()..writeln('<html><body>');
    for (final line in lines) {
      if (line.isEmpty) {
        buffer.writeln('<p><br/></p>');
        continue;
      }
      final escapedText = const HtmlEscape(
        HtmlEscapeMode.element,
      ).convert(line);
      buffer.writeln('<p>$escapedText</p>');
    }
    buffer.writeln('</body></html>');
    return buffer.toString();
  }

  String _buildEditableHtmlDocument(String html) {
    const editorEnhancements = '''
<style>
  img[data-docx-embed-id] {
    cursor: pointer;
    display: inline-block;
    user-select: all;
  }
  img[data-docx-embed-id].docx-selected-image {
    outline: 2px solid #2f80ed;
    outline-offset: 2px;
  }
</style>
<script>
  document.addEventListener('click', function (event) {
    document.querySelectorAll('img.docx-selected-image').forEach(function (image) {
      image.classList.remove('docx-selected-image');
    });
    if (event.target && event.target.matches('img[data-docx-embed-id]')) {
      event.target.classList.add('docx-selected-image');
    }
  });
  document.addEventListener('keydown', function (event) {
    if (event.key !== 'Backspace' && event.key !== 'Delete') {
      return;
    }
    var image = document.querySelector('img.docx-selected-image');
    if (!image) {
      return;
    }
    event.preventDefault();
    image.remove();
  });
</script>
''';
    final bodyPattern = RegExp(r'<body\b([^>]*)>', caseSensitive: false);
    final headClosePattern = RegExp(r'</head>', caseSensitive: false);
    final htmlOpenPattern = RegExp(r'<html\b[^>]*>', caseSensitive: false);

    String htmlWithEditorAssets;
    if (headClosePattern.hasMatch(html)) {
      htmlWithEditorAssets = html.replaceFirstMapped(headClosePattern, (match) {
        return '$editorEnhancements</head>';
      });
    } else if (htmlOpenPattern.hasMatch(html)) {
      htmlWithEditorAssets = html.replaceFirstMapped(htmlOpenPattern, (match) {
        return '${match.group(0)}<head>$editorEnhancements</head>';
      });
    } else {
      htmlWithEditorAssets = '<html><head>$editorEnhancements</head>$html</html>';
    }

    if (bodyPattern.hasMatch(htmlWithEditorAssets)) {
      return htmlWithEditorAssets.replaceFirstMapped(bodyPattern, (match) {
        final attributes = match.group(1) ?? '';
        return '<body$attributes contenteditable="true">';
      });
    }
    return '<html><head>$editorEnhancements</head><body contenteditable="true">$htmlWithEditorAssets</body></html>';
  }

  String _replaceHtmlBody(String originalHtml, String innerHtml) {
    final bodyPattern = RegExp(
      r'(<body\b[^>]*>)([\s\S]*?)(</body>)',
      caseSensitive: false,
    );
    if (bodyPattern.hasMatch(originalHtml)) {
      return originalHtml.replaceFirstMapped(bodyPattern, (match) {
        return '${match.group(1)}$innerHtml${match.group(3)}';
      });
    }
    return '<html><body>$innerHtml</body></html>';
  }

  String _decodeHtmlEditorResult(Object? value) {
    if (value == null) {
      return '';
    }
    final raw = value.toString();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is String && decoded.isNotEmpty) {
        return utf8.decode(base64Decode(decoded));
      }
    } catch (_) {}
    return utf8.decode(base64Decode(raw));
  }

  String _stripHtmlTags(String content) {
    return content
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</div>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</tr>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</td>', caseSensitive: false), '\t')
        .replaceAll(RegExp('<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .trim();
  }

  String _queryExtension(String path) {
    final fileName = path.split('/').last;
    final dotIndex = fileName.lastIndexOf('.');
    if (dotIndex < 0 || dotIndex == fileName.length - 1) {
      return '';
    }
    return fileName.substring(dotIndex + 1).toLowerCase();
  }

  bool _isOoxmlFile(List<int> bytes) {
    if (bytes.length < 4) {
      return false;
    }
    return bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        bytes[2] == 0x03 &&
        bytes[3] == 0x04;
  }

  @override
  void dispose() {
    textEditingController.dispose();
    textFocusNode.dispose();
    super.dispose();
  }
}

class _WordLoadedContent {
  const _WordLoadedContent({
    required this.html,
    required this.text,
    required this.type,
  });

  final String html;
  final String text;
  final String type;
}

class _WordNodeContent {
  const _WordNodeContent({required this.html, required this.text});

  final String html;
  final String text;
}
