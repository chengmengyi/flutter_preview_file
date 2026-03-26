import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:xml/xml.dart';

class ExcelFileController extends ChangeNotifier {
  ExcelFileController({required this.filePath});

  final String filePath;

  bool fileExists = false;
  bool loading = true;
  bool saving = false;
  bool isEditing = false;
  bool preparingSheet = false;
  String errorText = '';
  String currentSheetName = '';
  List<String> sheetNameList = [];
  Excel? excelDocument;
  List<List<String>> csvRows = [];
  WebViewController? htmlPreviewController;
  WebViewController? htmlEditorController;

  bool _initialized = false;

  bool get isCsvMode => excelDocument == null && csvRows.isNotEmpty;
  bool get showSheetTabs => sheetNameList.length > 1;

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
    sheetNameList = [];
    currentSheetName = '';
    excelDocument = null;
    csvRows = [];
    htmlPreviewController = null;
    htmlEditorController = null;
    notifyListeners();

    try {
      final bytes = await File(filePath).readAsBytes();
      final extension = _queryExtension(filePath);
      if (extension == 'csv') {
        final content = utf8.decode(bytes);
        csvRows = _parseCsv(content);
        sheetNameList = const ['Sheet1'];
        currentSheetName = sheetNameList.first;
      } else {
        if (extension != 'xlsx' && extension != 'xltx') {
          throw UnsupportedError(
            'Only .xlsx, .xltx, and .csv files support in-app Excel preview.',
          );
        }
        excelDocument = Excel.decodeBytes(_normalizeWorkbookBytes(bytes));
        sheetNameList = excelDocument!.tables.keys.toList();
        if (sheetNameList.isEmpty) {
          throw Exception('No worksheet found in the Excel file.');
        }
        final defaultSheet = excelDocument!.getDefaultSheet();
        currentSheetName = sheetNameList.contains(defaultSheet)
            ? defaultSheet!
            : sheetNameList.first;
      }
      await _preparePreviewController();
    } on UnsupportedError catch (error) {
      errorText = error.message?.toString().isNotEmpty == true
          ? error.message.toString()
          : 'Only .xlsx, .xltx, and .csv files support in-app Excel preview.';
    } catch (error) {
      errorText = _normalizeErrorText(error);
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
    await _prepareEditorController();
    isEditing = true;
    notifyListeners();
  }

  Future<void> cancelEditing() async {
    if (!isEditing || saving) {
      return;
    }
    isEditing = false;
    htmlEditorController = null;
    await _preparePreviewController();
    notifyListeners();
  }

  Future<void> selectSheet(String sheetName) async {
    if (sheetName == currentSheetName || loading || saving || isEditing) {
      return;
    }
    currentSheetName = sheetName;
    await _preparePreviewController();
    notifyListeners();
  }

  Future<void> save() async {
    if (!isEditing || saving || htmlEditorController == null) {
      return;
    }
    saving = true;
    notifyListeners();
    try {
      final editedCells = await _queryEditedCells();
      if (isCsvMode) {
        _applyEditedCellsToCsv(editedCells);
        await File(filePath).writeAsString(_encodeCsv(csvRows), flush: true);
      } else {
        _applyEditedCellsToWorkbook(editedCells);
        final bytes = excelDocument?.encode();
        if (bytes == null) {
          throw Exception('Failed to encode workbook.');
        }
        await File(filePath).writeAsBytes(bytes, flush: true);
      }
      isEditing = false;
      htmlEditorController = null;
      await _preparePreviewController();
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  Future<void> _preparePreviewController() async {
    preparingSheet = true;
    htmlPreviewController = null;
    notifyListeners();
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white);
    await controller.loadHtmlString(
      _buildSheetHtml(editable: false, sheetName: currentSheetName),
    );
    htmlPreviewController = controller;
    preparingSheet = false;
    notifyListeners();
  }

  Future<void> _prepareEditorController() async {
    preparingSheet = true;
    htmlEditorController = null;
    notifyListeners();
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white);
    await controller.loadHtmlString(
      _buildSheetHtml(editable: true, sheetName: currentSheetName),
    );
    htmlEditorController = controller;
    preparingSheet = false;
    notifyListeners();
  }

  Future<List<_EditedCell>> _queryEditedCells() async {
    final result = await htmlEditorController!.runJavaScriptReturningResult(
      "btoa(unescape(encodeURIComponent(JSON.stringify(Array.from(document.querySelectorAll('td[data-row][data-column]')).map(function(cell){return {row:Number(cell.dataset.row),column:Number(cell.dataset.column),value:(cell.innerText||'').replace(/\\u00a0/g,' ')};})))))",
    );
    final base64Text = _normalizeJsStringResult(result);
    if (base64Text.isEmpty) {
      return [];
    }
    final decoded = utf8.decode(base64Decode(base64Text));
    final list = jsonDecode(decoded) as List<dynamic>;
    return list
        .map(
          (item) => _EditedCell(
            row: item['row'] as int,
            column: item['column'] as int,
            value: (item['value'] ?? '').toString(),
          ),
        )
        .toList();
  }

  void _applyEditedCellsToWorkbook(List<_EditedCell> editedCells) {
    final workbook = excelDocument;
    if (workbook == null) {
      return;
    }
    final sheet = workbook[currentSheetName];
    final rows = sheet.rows;
    for (final cell in editedCells) {
      final originalData =
          cell.row < rows.length && cell.column < rows[cell.row].length
          ? rows[cell.row][cell.column]
          : null;
      final value = _buildCellValueFromText(originalData?.value, cell.value);
      sheet.updateCell(
        CellIndex.indexByColumnRow(
          columnIndex: cell.column,
          rowIndex: cell.row,
        ),
        value,
      );
    }
  }

  void _applyEditedCellsToCsv(List<_EditedCell> editedCells) {
    for (final cell in editedCells) {
      while (csvRows.length <= cell.row) {
        csvRows.add([]);
      }
      while (csvRows[cell.row].length <= cell.column) {
        csvRows[cell.row].add('');
      }
      csvRows[cell.row][cell.column] = cell.value;
    }
  }

  String _buildSheetHtml({required bool editable, required String sheetName}) {
    final sheetContent = isCsvMode
        ? _buildCsvHtmlTable(editable)
        : _buildWorkbookHtmlTable(sheetName, editable);
    final escapedSheetName = const HtmlEscape(
      HtmlEscapeMode.element,
    ).convert(sheetName);
    return '''
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
  <style>
    :root {
      color-scheme: light;
      --grid: #d8dee9;
      --sheet-bg: #f5f8f5;
      --header-bg: #eef6f0;
      --header-text: #30513b;
      --cell-bg: #ffffff;
      --text: #191919;
      --accent: #177e2f;
      --index-bg: #f2f5f7;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: linear-gradient(180deg, #edf5ee 0%, #f8faf8 100%);
      color: var(--text);
      font-family: Georgia, "Times New Roman", serif;
    }
    .sheet-shell {
      padding: 16px;
    }
    .sheet-card {
      background: var(--sheet-bg);
      border: 1px solid rgba(23, 126, 47, 0.14);
      border-radius: 18px;
      overflow: hidden;
      box-shadow: 0 16px 36px rgba(23, 126, 47, 0.08);
    }
    .sheet-head {
      padding: 14px 18px;
      background: linear-gradient(90deg, #177e2f 0%, #2ea64a 100%);
      color: #ffffff;
      font-size: 16px;
      font-weight: 700;
      letter-spacing: 0.02em;
    }
    .sheet-wrap {
      overflow: auto;
      padding: 12px;
    }
    table {
      border-collapse: collapse;
      min-width: 100%;
      background: var(--cell-bg);
    }
    th, td {
      border: 1px solid var(--grid);
      min-width: 96px;
      padding: 10px 12px;
      font-size: 14px;
      line-height: 1.4;
      vertical-align: middle;
      word-break: break-word;
      white-space: pre-wrap;
    }
    th {
      position: sticky;
      top: 0;
      z-index: 2;
      background: var(--header-bg);
      color: var(--header-text);
      font-weight: 700;
      text-align: center;
    }
    .index {
      position: sticky;
      left: 0;
      z-index: 1;
      min-width: 52px;
      background: var(--index-bg);
      text-align: center;
      color: #60707f;
      font-weight: 700;
    }
    th.index {
      z-index: 3;
    }
    td[data-editable="true"] {
      outline: none;
      cursor: text;
    }
    td[data-editable="true"]:focus {
      box-shadow: inset 0 0 0 2px rgba(23, 126, 47, 0.45);
      background: #f5fff6;
    }
  </style>
</head>
<body>
  <div class="sheet-shell">
    <div class="sheet-card">
      <div class="sheet-head">$escapedSheetName</div>
      <div class="sheet-wrap">
        $sheetContent
      </div>
    </div>
  </div>
</body>
</html>
''';
  }

  String _buildWorkbookHtmlTable(String sheetName, bool editable) {
    final workbook = excelDocument;
    if (workbook == null) {
      return '<div></div>';
    }
    final sheet = workbook[sheetName];
    final rowCount = sheet.maxRows > 0 ? sheet.maxRows : 1;
    final columnCount = sheet.maxColumns > 0 ? sheet.maxColumns : 1;
    final rows = sheet.rows;
    final mergeStarts = <String, _SpanCell>{};
    final coveredCells = <String>{};
    for (final span in sheet.spannedItems) {
      final parts = span.split(':');
      if (parts.length != 2) {
        continue;
      }
      final start = CellIndex.indexByString(parts.first);
      final end = CellIndex.indexByString(parts.last);
      mergeStarts['${start.rowIndex}_${start.columnIndex}'] = _SpanCell(
        row: start.rowIndex,
        column: start.columnIndex,
        rowSpan: end.rowIndex - start.rowIndex + 1,
        columnSpan: end.columnIndex - start.columnIndex + 1,
      );
      for (var row = start.rowIndex; row <= end.rowIndex; row++) {
        for (
          var column = start.columnIndex;
          column <= end.columnIndex;
          column++
        ) {
          if (row == start.rowIndex && column == start.columnIndex) {
            continue;
          }
          coveredCells.add('${row}_$column');
        }
      }
    }

    final buffer = StringBuffer();
    buffer.writeln('<table>');
    buffer.writeln('<thead><tr><th class="index"></th>');
    for (var column = 0; column < columnCount; column++) {
      buffer.writeln(
        '<th>${const HtmlEscape(HtmlEscapeMode.element).convert(_columnLabel(column))}</th>',
      );
    }
    buffer.writeln('</tr></thead>');
    buffer.writeln('<tbody>');

    for (var row = 0; row < rowCount; row++) {
      buffer.writeln('<tr>');
      buffer.writeln('<th class="index">${row + 1}</th>');
      for (var column = 0; column < columnCount; column++) {
        final key = '${row}_$column';
        if (coveredCells.contains(key)) {
          continue;
        }
        final span = mergeStarts[key];
        final data = row < rows.length && column < rows[row].length
            ? rows[row][column]
            : null;
        final cellText = _cellDisplayText(data?.value);
        final style = _buildCellCss(
          data: data,
          sheet: sheet,
          row: row,
          column: column,
        );
        buffer.write(
          '<td data-row="$row" data-column="$column" data-editable="$editable"'
          '${editable ? ' contenteditable="true"' : ''}'
          '${span != null && span.rowSpan > 1 ? ' rowspan="${span.rowSpan}"' : ''}'
          '${span != null && span.columnSpan > 1 ? ' colspan="${span.columnSpan}"' : ''}'
          '${style.isNotEmpty ? ' style="$style"' : ''}>'
          '${_escapeHtml(cellText).replaceAll('\n', '<br/>')}'
          '</td>',
        );
      }
      buffer.writeln('</tr>');
    }

    buffer.writeln('</tbody></table>');
    return buffer.toString();
  }

  String _buildCsvHtmlTable(bool editable) {
    final rowCount = csvRows.isNotEmpty ? csvRows.length : 1;
    var columnCount = 1;
    for (final row in csvRows) {
      if (row.length > columnCount) {
        columnCount = row.length;
      }
    }
    final buffer = StringBuffer();
    buffer.writeln('<table>');
    buffer.writeln('<thead><tr><th class="index"></th>');
    for (var column = 0; column < columnCount; column++) {
      buffer.writeln(
        '<th>${const HtmlEscape(HtmlEscapeMode.element).convert(_columnLabel(column))}</th>',
      );
    }
    buffer.writeln('</tr></thead><tbody>');
    for (var row = 0; row < rowCount; row++) {
      buffer.writeln('<tr>');
      buffer.writeln('<th class="index">${row + 1}</th>');
      for (var column = 0; column < columnCount; column++) {
        final value = row < csvRows.length && column < csvRows[row].length
            ? csvRows[row][column]
            : '';
        buffer.write(
          '<td data-row="$row" data-column="$column" data-editable="$editable"'
          '${editable ? ' contenteditable="true"' : ''}>'
          '${_escapeHtml(value).replaceAll('\n', '<br/>')}'
          '</td>',
        );
      }
      buffer.writeln('</tr>');
    }
    buffer.writeln('</tbody></table>');
    return buffer.toString();
  }

  String _buildCellCss({
    required Data? data,
    required Sheet sheet,
    required int row,
    required int column,
  }) {
    final style = data?.cellStyle;
    final css = <String>[];
    final width = sheet.getColumnWidths[column];
    if (width != null && width > 0) {
      css.add('min-width:${(width * 9).round()}px');
    }
    final height = sheet.getRowHeights[row];
    if (height != null && height > 0) {
      css.add('height:${(height * 1.4).round()}px');
    }
    if (style != null) {
      if (style.backgroundColor.colorHex != 'none') {
        css.add('background:${_excelColorToCss(style.backgroundColor)}');
      }
      css.add('color:${_excelColorToCss(style.fontColor)}');
      if (style.fontSize != null) {
        css.add('font-size:${style.fontSize}px');
      }
      if (style.fontFamily?.isNotEmpty == true) {
        css.add('font-family:${style.fontFamily}');
      }
      if (style.isBold) {
        css.add('font-weight:700');
      }
      if (style.isItalic) {
        css.add('font-style:italic');
      }
      if (style.underline != Underline.None) {
        css.add('text-decoration:underline');
      }
      css.add('text-align:${_horizontalAlign(style.horizontalAlignment)}');
      css.add('vertical-align:${_verticalAlign(style.verticalAlignment)}');
    }
    return css.join(';');
  }

  String _cellDisplayText(CellValue? value) {
    if (value == null) {
      return '';
    }
    if (value is TextCellValue) {
      return value.value.toString();
    }
    return value.toString();
  }

  CellValue? _buildCellValueFromText(CellValue? originalValue, String rawText) {
    final text = rawText.replaceAll('\r\n', '\n').trimRight();
    if (text.isEmpty) {
      return null;
    }

    if (originalValue is FormulaCellValue) {
      return text.startsWith('=')
          ? FormulaCellValue(text)
          : TextCellValue(text);
    }
    if (originalValue is IntCellValue) {
      final value = int.tryParse(text);
      return value != null ? IntCellValue(value) : TextCellValue(text);
    }
    if (originalValue is DoubleCellValue) {
      final value = double.tryParse(text);
      return value != null ? DoubleCellValue(value) : TextCellValue(text);
    }
    if (originalValue is BoolCellValue) {
      final lower = text.toLowerCase();
      if (lower == 'true' || lower == 'false') {
        return BoolCellValue(lower == 'true');
      }
      return TextCellValue(text);
    }
    if (originalValue is DateTimeCellValue) {
      final value = DateTime.tryParse(text);
      return value != null
          ? DateTimeCellValue.fromDateTime(value)
          : TextCellValue(text);
    }
    if (originalValue is DateCellValue) {
      final value = DateTime.tryParse(text);
      return value != null
          ? DateCellValue.fromDateTime(value)
          : TextCellValue(text);
    }
    final intValue = int.tryParse(text);
    if (intValue != null) {
      return IntCellValue(intValue);
    }
    final doubleValue = double.tryParse(text);
    if (doubleValue != null) {
      return DoubleCellValue(doubleValue);
    }
    final lower = text.toLowerCase();
    if (lower == 'true' || lower == 'false') {
      return BoolCellValue(lower == 'true');
    }
    if (text.startsWith('=')) {
      return FormulaCellValue(text);
    }
    return TextCellValue(text);
  }

  String _queryExtension(String path) {
    final fileName = path.split('/').last;
    final dotIndex = fileName.lastIndexOf('.');
    if (dotIndex < 0 || dotIndex == fileName.length - 1) {
      return '';
    }
    return fileName.substring(dotIndex + 1).toLowerCase();
  }

  String _normalizeJsStringResult(Object? value) {
    if (value == null) {
      return '';
    }
    final raw = value.toString();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is String) {
        return decoded;
      }
    } catch (_) {}
    return raw;
  }

  List<int> _normalizeWorkbookBytes(List<int> bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final stylesFile = archive.findFile('xl/styles.xml');
      if (stylesFile == null) {
        return bytes;
      }

      final xmlDocument = XmlDocument.parse(
        utf8.decode(stylesFile.content as List<int>),
      );
      final remap = <String, String>{};
      var nextCustomNumFmtId = 164;

      for (final numFmt in xmlDocument.findAllElements('numFmt')) {
        final rawId = numFmt.getAttribute('numFmtId') ?? '';
        final numFmtId = int.tryParse(rawId);
        if (numFmtId == null || numFmtId >= 164) {
          if (numFmtId != null && numFmtId >= nextCustomNumFmtId) {
            nextCustomNumFmtId = numFmtId + 1;
          }
          continue;
        }
        final newId = nextCustomNumFmtId++;
        remap[rawId] = newId.toString();
        numFmt.setAttribute('numFmtId', newId.toString());
      }

      if (remap.isEmpty) {
        return bytes;
      }

      for (final xf in xmlDocument.findAllElements('xf')) {
        final rawId = xf.getAttribute('numFmtId');
        final newId = remap[rawId];
        if (newId != null) {
          xf.setAttribute('numFmtId', newId);
        }
      }

      final updatedXml = utf8.encode(xmlDocument.toXmlString());
      archive[archive.files.indexOf(
        stylesFile,
      )] = ArchiveFile(stylesFile.name, updatedXml.length, updatedXml)
        ..compress = stylesFile.compress
        ..mode = stylesFile.mode
        ..lastModTime = stylesFile.lastModTime;

      return ZipEncoder().encode(archive) ?? bytes;
    } catch (_) {
      return bytes;
    }
  }

  String _normalizeErrorText(Object error) {
    final raw = error.toString();
    return raw
        .replaceFirst('Exception: ', '')
        .replaceFirst('UnsupportedError: ', '')
        .trim();
  }

  List<List<String>> _parseCsv(String input) {
    final rows = <List<String>>[];
    final currentRow = <String>[];
    final currentValue = StringBuffer();
    var insideQuotes = false;
    for (var index = 0; index < input.length; index++) {
      final char = input[index];
      if (char == '"') {
        if (insideQuotes &&
            index + 1 < input.length &&
            input[index + 1] == '"') {
          currentValue.write('"');
          index++;
        } else {
          insideQuotes = !insideQuotes;
        }
        continue;
      }
      if (!insideQuotes && char == ',') {
        currentRow.add(currentValue.toString());
        currentValue.clear();
        continue;
      }
      if (!insideQuotes && (char == '\n' || char == '\r')) {
        if (char == '\r' &&
            index + 1 < input.length &&
            input[index + 1] == '\n') {
          index++;
        }
        currentRow.add(currentValue.toString());
        currentValue.clear();
        rows.add(List<String>.from(currentRow));
        currentRow.clear();
        continue;
      }
      currentValue.write(char);
    }
    currentRow.add(currentValue.toString());
    if (currentRow.isNotEmpty) {
      rows.add(List<String>.from(currentRow));
    }
    return rows;
  }

  String _encodeCsv(List<List<String>> rows) {
    return rows
        .map((row) {
          return row
              .map((cell) {
                final needsQuotes =
                    cell.contains(',') ||
                    cell.contains('"') ||
                    cell.contains('\n') ||
                    cell.contains('\r');
                final escaped = cell.replaceAll('"', '""');
                return needsQuotes ? '"$escaped"' : escaped;
              })
              .join(',');
        })
        .join('\r\n');
  }

  String _columnLabel(int column) {
    var index = column;
    var label = '';
    while (index >= 0) {
      label = String.fromCharCode(65 + (index % 26)) + label;
      index = (index ~/ 26) - 1;
    }
    return label;
  }

  String _excelColorToCss(ExcelColor color) {
    final hex = color.colorHex;
    if (hex == 'none' || hex.length != 8) {
      return '#000000';
    }
    return '#${hex.substring(2)}';
  }

  String _horizontalAlign(HorizontalAlign align) {
    return switch (align) {
      HorizontalAlign.Center => 'center',
      HorizontalAlign.Right => 'right',
      _ => 'left',
    };
  }

  String _verticalAlign(VerticalAlign align) {
    return switch (align) {
      VerticalAlign.Top => 'top',
      VerticalAlign.Center => 'middle',
      _ => 'bottom',
    };
  }

  String _escapeHtml(String text) {
    return const HtmlEscape(HtmlEscapeMode.element).convert(text);
  }
}

class _EditedCell {
  _EditedCell({required this.row, required this.column, required this.value});

  final int row;
  final int column;
  final String value;
}

class _SpanCell {
  _SpanCell({
    required this.row,
    required this.column,
    required this.rowSpan,
    required this.columnSpan,
  });

  final int row;
  final int column;
  final int rowSpan;
  final int columnSpan;
}
