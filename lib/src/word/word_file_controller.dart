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
      originalHtmlDocument = loadedFileType == 'html' ? loadedContent.html : '';
      if (isHtmlEditable) {
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
    if (isHtmlEditable) {
      await _prepareHtmlEditor();
    }
    isEditing = true;
    textEditingController.text = plainText;
    notifyListeners();
    if (!isHtmlEditable) {
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
      return _buildOoxmlContent(documentXml);
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

  _WordLoadedContent _buildOoxmlContent(XmlDocument documentXml) {
    final body = documentXml.findAllElements('w:body').firstOrNull;
    if (body == null) {
      return const _WordLoadedContent(html: '', text: '', type: 'ooxml');
    }
    final htmlBuffer = StringBuffer()..writeln('<html><body>');
    final textBuffer = StringBuffer();
    var listOpened = false;

    for (final node in body.childElements) {
      if (node.name.qualified == 'w:p') {
        final paragraphContent = _parseParagraphContent(node);
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
        final tableContent = _parseTableContent(node);
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

  _WordNodeContent _parseParagraphContent(XmlElement paragraph) {
    final htmlBuffer = StringBuffer();
    final textBuffer = StringBuffer();
    for (final run in paragraph.findElements('w:r')) {
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

  _WordNodeContent _parseTableContent(XmlElement table) {
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
          final paragraphContent = _parseParagraphContent(paragraph);
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
    final bodyPattern = RegExp(r'<body\b([^>]*)>', caseSensitive: false);
    if (bodyPattern.hasMatch(html)) {
      return html.replaceFirstMapped(bodyPattern, (match) {
        final attributes = match.group(1) ?? '';
        return '<body$attributes contenteditable="true">';
      });
    }
    return '<html><body contenteditable="true">$html</body></html>';
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
