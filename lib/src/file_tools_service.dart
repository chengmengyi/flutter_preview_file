import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import '../flutter_preview_file.dart';
import '../flutter_preview_file_platform_interface.dart';
import 'pdf/pdf_to_word_converter.dart';
import 'word/word_to_pdf_converter.dart';

typedef FileToolsProgressCallback = void Function(double progress);

class FileToolsService {
  FileToolsService._();

  static final FileToolsService instance = FileToolsService._();

  static const Set<String> _pdfExtensions = {"pdf"};
  static const Set<String> _wordExtensions = {
    "doc",
    "docx",
    "dot",
    "dotx",
    "rtf",
    "wps",
    "txt",
  };
  static const Set<String> _excelExtensions = {
    "xls",
    "xlsx",
    "xlt",
    "xltx",
    "csv",
    "et",
  };

  Future<List<FileToolsFileInfo>> queryFileList(
    FileToolsDocumentType type,
  ) async {
    if (!Platform.isAndroid) {
      return <FileToolsFileInfo>[];
    }
    try {
      final rawFileList = await _scanFileList(type);
      return rawFileList.map(_toFileInfo).toList(growable: false);
    } catch (_) {
      return <FileToolsFileInfo>[];
    }
  }

  FileToolsDocumentType? matchDocumentsType(String path) {
    return _matchDocumentsType(path);
  }

  Future<FileToolsFileInfo?> renameFile({
    required FileToolsFileInfo fileInfo,
    required String newNameWithoutExtension,
  }) async {
    final oldPath = fileInfo.path ?? "";
    final targetBaseName = newNameWithoutExtension.trim();
    if (oldPath.isEmpty || targetBaseName.isEmpty) {
      return null;
    }
    final oldFile = File(oldPath);
    if (!await oldFile.exists()) {
      return null;
    }
    final extension = _queryFileExtension(fileInfo.name ?? oldPath);
    final targetName = extension.isEmpty
        ? targetBaseName
        : "$targetBaseName.$extension";
    final targetPath = "${oldFile.parent.path}/$targetName";
    if (targetPath == oldPath) {
      final stat = await oldFile.stat();
      return FileToolsFileInfo(
        name: targetName,
        type: _matchDocumentsType(targetPath),
        updateTime: stat.modified.millisecondsSinceEpoch,
        size: stat.size,
        path: oldPath,
        bookmark: fileInfo.bookmark,
      );
    }
    final renamedFile = await oldFile.rename(targetPath);
    final stat = await renamedFile.stat();
    final resolvedPath = await renamedFile.resolveSymbolicLinks();
    return FileToolsFileInfo(
      name: targetName,
      type: _matchDocumentsType(resolvedPath),
      updateTime: stat.modified.millisecondsSinceEpoch,
      size: stat.size,
      path: resolvedPath,
      bookmark: fileInfo.bookmark,
    );
  }

  Future<bool> deleteFile(String path) async {
    if (path.isEmpty) {
      return false;
    }
    final file = File(path);
    if (!await file.exists()) {
      return true;
    }
    await file.delete();
    return true;
  }

  Future<bool> fileExists(String path) => File(path).exists();

  List<FileToolsFileInfo> sortFileList(
    List<FileToolsFileInfo> fileList,
    FileToolsSortType sortType,
  ) {
    final result = List<FileToolsFileInfo>.from(fileList);
    switch (sortType) {
      case FileToolsSortType.newest:
        result.sort((a, b) => (b.updateTime ?? 0).compareTo(a.updateTime ?? 0));
        break;
      case FileToolsSortType.oldest:
        result.sort((a, b) => (a.updateTime ?? 0).compareTo(b.updateTime ?? 0));
        break;
      case FileToolsSortType.az:
        result.sort(
          (a, b) => (a.name ?? "").toLowerCase().compareTo(
            (b.name ?? "").toLowerCase(),
          ),
        );
        break;
      case FileToolsSortType.za:
        result.sort(
          (a, b) => (b.name ?? "").toLowerCase().compareTo(
            (a.name ?? "").toLowerCase(),
          ),
        );
        break;
    }
    return result;
  }

  Future<FileToolsFileInfo> mergePdfFiles({
    required List<FileToolsFileInfo> fileList,
    FileToolsProgressCallback? onProgress,
    FileToolsTaskControl? taskControl,
  }) async {
    if (fileList.length < 2) {
      throw Exception("At least two files should be selected");
    }
    onProgress?.call(0);
    final result = await _runMergePdfFilesInBackground(
      fileList: fileList,
      onProgress: onProgress,
      taskControl: taskControl,
    );
    await taskControl?.checkpoint();
    await FlutterPreviewFile.scanFile(result.path ?? "");
    onProgress?.call(1);
    return result;
  }

  Future<FileToolsFileInfo> splitPdfFile({
    required FileToolsFileInfo fileInfo,
    required List<int> selectedPageIndexList,
    FileToolsProgressCallback? onProgress,
    FileToolsTaskControl? taskControl,
  }) async {
    if (selectedPageIndexList.isEmpty) {
      throw Exception("Please select at least one page");
    }
    final path = fileInfo.path ?? "";
    if (path.isEmpty) {
      throw Exception("File path is invalid");
    }
    final file = File(path);
    if (!await file.exists()) {
      throw Exception("The file does not exist. Please select another file");
    }
    onProgress?.call(0);
    final result = await _runFileToolsTaskInBackground(
      isolateEntry: _splitPdfFileIsolateEntry,
      payload: <String, dynamic>{
        "fileInfo": _fileInfoToMap(fileInfo),
        "selectedPageIndexList": List<int>.from(selectedPageIndexList),
      },
      fallbackErrorMessage: "Failed to split PDF",
      onProgress: onProgress,
      taskControl: taskControl,
    );
    await taskControl?.checkpoint();
    await FlutterPreviewFile.scanFile(result.path ?? "");
    onProgress?.call(1);
    return result;
  }

  Future<FileToolsFileInfo> convertWordToPdfFile({
    required FileToolsFileInfo fileInfo,
    FileToolsProgressCallback? onProgress,
    FileToolsTaskControl? taskControl,
  }) async {
    final path = fileInfo.path ?? "";
    if (path.isEmpty) {
      throw Exception("File path is invalid");
    }
    final sourceFile = File(path);
    if (!await sourceFile.exists()) {
      throw Exception("The file does not exist. Please select another file");
    }
    onProgress?.call(0);
    final canRunInBackground = await WordToPdfConverter.canConvertInBackground(
      inputPath: path,
    );
    if (canRunInBackground) {
      final assetFontBytes =
          await WordToPdfConverter.loadDefaultPdfFontAssetBytes();
      final result = await _runFileToolsTaskInBackground(
        isolateEntry: _convertWordToPdfOoxmlIsolateEntry,
        payload: <String, dynamic>{
          "fileInfo": _fileInfoToMap(fileInfo),
          "assetFontBytes": assetFontBytes,
        },
        fallbackErrorMessage: "Failed to convert Word to PDF",
        onProgress: onProgress,
        taskControl: taskControl,
      );
      await taskControl?.checkpoint();
      await FlutterPreviewFile.scanFile(result.path ?? "");
      onProgress?.call(1);
      return result;
    }
    await taskControl?.checkpoint();
    onProgress?.call(0.15);
    final outputFile = await _createSequentialOutputFile(
      prefix: "word2pdf",
      extension: "pdf",
    );
    await taskControl?.checkpoint();
    onProgress?.call(0.3);
    try {
      await FlutterPreviewFile.convertWordToPdf(
        inputPath: path,
        outputPath: outputFile.path,
      );
      await taskControl?.checkpoint();
      onProgress?.call(0.9);
      await FlutterPreviewFile.scanFile(outputFile.path);
      final stat = await outputFile.stat();
      onProgress?.call(1);
      return FileToolsFileInfo(
        name: outputFile.uri.pathSegments.last,
        type: FileToolsDocumentType.pdf,
        updateTime: stat.modified.millisecondsSinceEpoch,
        size: stat.size,
        path: outputFile.path,
      );
    } catch (_) {
      if (await outputFile.exists()) {
        await outputFile.delete();
      }
      rethrow;
    }
  }

  Future<FileToolsFileInfo> convertPdfToWordFile({
    required FileToolsFileInfo fileInfo,
    FileToolsProgressCallback? onProgress,
    FileToolsTaskControl? taskControl,
  }) async {
    final path = fileInfo.path ?? "";
    if (path.isEmpty) {
      throw Exception("File path is invalid");
    }
    final sourceFile = File(path);
    if (!await sourceFile.exists()) {
      throw Exception("The file does not exist. Please select another file");
    }
    onProgress?.call(0);
    await taskControl?.checkpoint();
    final outputFile = await _createSequentialOutputFile(
      prefix: "pdf2word",
      extension: "docx",
    );
    onProgress?.call(0.2);
    try {
      final List<Uint8List?> pageImageBytesList = <Uint8List?>[];
      if (await _pdfMightContainImages(sourceFile)) {
        final int pageCount = await FlutterPreviewFile.getPdfPageCount(path);
        for (int pageIndex = 0; pageIndex < pageCount; pageIndex++) {
          await taskControl?.checkpoint();
          final Uint8List? pageImageBytes =
              await FlutterPreviewFile.renderPdfPageToImageBytes(
                pdfPath: path,
                pageIndex: pageIndex,
                width: 1200,
              );
          pageImageBytesList.add(pageImageBytes);
          onProgress?.call(0.2 + ((pageIndex + 1) / pageCount) * 0.35);
        }
      }
      await taskControl?.checkpoint();
      await PdfToWordConverter.convert(
        inputPath: path,
        outputPath: outputFile.path,
        pageImageBytesList: pageImageBytesList.isEmpty
            ? null
            : pageImageBytesList,
        onProgress: (double progress) {
          onProgress?.call(0.55 + progress * 0.35);
        },
      );
      await taskControl?.checkpoint();
      await FlutterPreviewFile.scanFile(outputFile.path);
      final stat = await outputFile.stat();
      onProgress?.call(1);
      return FileToolsFileInfo(
        name: outputFile.uri.pathSegments.last,
        type: FileToolsDocumentType.word,
        updateTime: stat.modified.millisecondsSinceEpoch,
        size: stat.size,
        path: outputFile.path,
      );
    } catch (_) {
      if (await outputFile.exists()) {
        await outputFile.delete();
      }
      rethrow;
    }
  }

  Future<bool> _pdfMightContainImages(File file) async {
    final bytes = await file.readAsBytes();
    final content = String.fromCharCodes(bytes, 0, bytes.length);
    return content.contains('/Subtype/Image') ||
        content.contains('/Subtype /Image');
  }

  Future<FileToolsFileInfo> extractPdfTextFile({
    required FileToolsFileInfo fileInfo,
    required List<int> selectedPageIndexList,
    FileToolsProgressCallback? onProgress,
    FileToolsTaskControl? taskControl,
  }) async {
    final path = fileInfo.path ?? "";
    if (path.isEmpty) {
      throw Exception("File path is invalid");
    }
    final sourceFile = File(path);
    if (!await sourceFile.exists()) {
      throw Exception("The file does not exist. Please select another file");
    }
    if (selectedPageIndexList.isEmpty) {
      throw Exception("Please select at least one page");
    }
    onProgress?.call(0);
    final result = await _runFileToolsTaskInBackground(
      isolateEntry: _extractPdfTextFileIsolateEntry,
      payload: <String, dynamic>{
        "fileInfo": _fileInfoToMap(fileInfo),
        "selectedPageIndexList": List<int>.from(selectedPageIndexList),
      },
      fallbackErrorMessage: "Failed to extract text",
      onProgress: onProgress,
      taskControl: taskControl,
    );
    await taskControl?.checkpoint();
    await FlutterPreviewFile.scanFile(result.path ?? "");
    onProgress?.call(1);
    return result;
  }

  Future<List<FileToolsFileInfo>> queryAllImages() async {
    if (!Platform.isAndroid) {
      return <FileToolsFileInfo>[];
    }
    final permissionState = await PhotoManager.requestPermissionExtend();
    if (!permissionState.hasAccess) {
      return <FileToolsFileInfo>[];
    }
    final pathList = await PhotoManager.getAssetPathList(
      onlyAll: true,
      type: RequestType.image,
      filterOption: FilterOptionGroup(
        imageOption: const FilterOption(
          sizeConstraint: SizeConstraint(ignoreSize: true),
        ),
        orders: const <OrderOption>[
          OrderOption(type: OrderOptionType.updateDate, asc: false),
        ],
      ),
    );
    if (pathList.isEmpty) {
      return <FileToolsFileInfo>[];
    }
    final assetPath = pathList.first;
    final totalCount = await assetPath.assetCountAsync;
    if (totalCount <= 0) {
      return <FileToolsFileInfo>[];
    }
    const pageSize = 200;
    final List<FileToolsFileInfo> result = <FileToolsFileInfo>[];
    for (int page = 0; page * pageSize < totalCount; page++) {
      final assetList = await assetPath.getAssetListPaged(
        page: page,
        size: pageSize,
      );
      if (assetList.isEmpty) {
        break;
      }
      final fileBeanList = await Future.wait<FileToolsFileInfo?>(
        assetList.map(_toImageFileInfo),
      );
      result.addAll(fileBeanList.whereType<FileToolsFileInfo>());
      await Future<void>.delayed(Duration.zero);
    }
    return result;
  }

  Future<Uint8List?> queryPdfImage({
    required FileToolsFileInfo fileInfo,
    required int pageIndex,
    int? width,
  }) async {
    final path = fileInfo.path ?? "";
    if (path.isEmpty) {
      return null;
    }
    final file = File(path);
    if (!await file.exists()) {
      return null;
    }
    final pageCount = await FlutterPreviewFile.getPdfPageCount(path);
    if (pageIndex < 0 || pageIndex >= pageCount) {
      return null;
    }
    final bytes = await FlutterPreviewFile.renderPdfPageToImageBytes(
      pdfPath: path,
      pageIndex: pageIndex,
      width: width,
    );
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    return bytes;
  }

  Future<FileToolsFileInfo> generatePdfFromImages({
    required List<FileToolsFileInfo> imageList,
    String? outputFileName,
    FileToolsProgressCallback? onProgress,
    FileToolsTaskControl? taskControl,
  }) async {
    if (imageList.isEmpty) {
      throw Exception("Please select at least one image");
    }
    onProgress?.call(0);
    if (Platform.isAndroid) {
      final outputFile = await _createImagesToPdfOutputFile(
        outputFileName: outputFileName,
      );
      try {
        onProgress?.call(0.2);
        final result = await _runFileToolsTaskInBackground(
          isolateEntry: _generatePdfFromImagesAndroidIsolateEntry,
          payload: <String, dynamic>{
            "imageList":
                imageList.map(_fileInfoToMap).toList(growable: false),
            "outputPath": outputFile.path,
            "rootIsolateToken": RootIsolateToken.instance,
          },
          fallbackErrorMessage: "Failed to generate PDF",
          onProgress: onProgress,
          taskControl: taskControl,
        );
        await taskControl?.checkpoint();
        await FlutterPreviewFile.scanFile(result.path ?? "");
        onProgress?.call(1);
        return result;
      } catch (_) {
        if (await outputFile.exists()) {
          await outputFile.delete();
        }
        rethrow;
      }
    }
    final result = await _runFileToolsTaskInBackground(
      isolateEntry: _generatePdfFromImagesIsolateEntry,
      payload: <String, dynamic>{
        "imageList": imageList.map(_fileInfoToMap).toList(growable: false),
        "outputFileName": outputFileName,
      },
      fallbackErrorMessage: "Failed to generate PDF",
      onProgress: onProgress,
      taskControl: taskControl,
    );
    await taskControl?.checkpoint();
    await FlutterPreviewFile.scanFile(result.path ?? "");
    onProgress?.call(1);
    return result;
  }

  Future<FileToolsPdfToImagesZipResult> extractPdfToImagesZip({
    required List<FileToolsFileInfo> fileList,
    FileToolsProgressCallback? onProgress,
    FileToolsTaskControl? taskControl,
  }) async {
    if (fileList.isEmpty) {
      throw Exception("Please select at least one file");
    }
    onProgress?.call(0);
    final pdfTaskList = <_PdfExtractTask>[];
    int totalPageCount = 0;
    for (final bean in fileList) {
      await taskControl?.checkpoint();
      final path = bean.path ?? "";
      if (path.isEmpty) {
        throw Exception("File path is invalid");
      }
      final file = File(path);
      if (!await file.exists()) {
        throw Exception("The file does not exist. Please select another file");
      }
      final pageCount = await FlutterPreviewFile.getPdfPageCount(path);
      if (pageCount <= 0) {
        continue;
      }
      pdfTaskList.add(_PdfExtractTask(fileInfo: bean, pageCount: pageCount));
      totalPageCount += pageCount;
    }
    if (totalPageCount <= 0) {
      throw Exception("Failed to extract images from PDF");
    }
    final tempDirectory = await Directory.systemTemp.createTemp(
      "pdf_to_images_",
    );
    File? zipFile;
    try {
      final totalStepCount = totalPageCount * 2;
      int completedStepCount = 0;
      final imageFileList = <File>[];
      for (int pdfIndex = 0; pdfIndex < pdfTaskList.length; pdfIndex++) {
        final task = pdfTaskList[pdfIndex];
        final pdfPath = task.fileInfo.path ?? "";
        final baseName = _sanitizeEntryName(
          _queryFileBaseName(task.fileInfo.name ?? "pdf_${pdfIndex + 1}"),
        );
        for (int pageIndex = 0; pageIndex < task.pageCount; pageIndex++) {
          await taskControl?.checkpoint();
          final imageFile = File(
            "${tempDirectory.path}/${(pdfIndex + 1).toString().padLeft(2, "0")}_${baseName}_${(pageIndex + 1).toString().padLeft(3, "0")}.png",
          );
          final outputPath = await FlutterPreviewFile.renderPdfPageToImage(
            pdfPath: pdfPath,
            pageIndex: pageIndex,
            outputPath: imageFile.path,
          );
          if ((outputPath ?? "").isEmpty) {
            throw Exception("Failed to extract images from PDF");
          }
          imageFileList.add(File(outputPath!));
          completedStepCount++;
          onProgress?.call(completedStepCount / totalStepCount);
        }
      }
      if (imageFileList.isEmpty) {
        throw Exception("Failed to extract images from PDF");
      }
      await taskControl?.checkpoint();
      zipFile = await _createSequentialOutputFile(
        prefix: "Zip",
        extension: "zip",
      );
      final encoder = ZipFileEncoder();
      try {
        encoder.create(zipFile.path);
        for (final imageFile in imageFileList) {
          await taskControl?.checkpoint();
          encoder.addFile(imageFile);
          completedStepCount++;
          onProgress?.call(completedStepCount / totalStepCount);
        }
      } finally {
        encoder.close();
      }
      await FlutterPreviewFile.scanFile(zipFile.path);
      final stat = await zipFile.stat();
      onProgress?.call(1);
      return FileToolsPdfToImagesZipResult(
        imageCount: totalPageCount,
        fileInfo: FileToolsFileInfo(
          name: zipFile.uri.pathSegments.last,
          updateTime: stat.modified.millisecondsSinceEpoch,
          size: stat.size,
          path: zipFile.path,
        ),
      );
    } catch (_) {
      if (zipFile != null && await zipFile.exists()) {
        await zipFile.delete();
      }
      rethrow;
    } finally {
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    }
  }

  Future<int> savePdfImagesToGallery({
    required List<FileToolsFileInfo> fileList,
    FileToolsProgressCallback? onProgress,
  }) async {
    if (fileList.isEmpty) {
      throw Exception("Please select at least one file");
    }
    final pdfTaskList = <_PdfExtractTask>[];
    int totalPageCount = 0;
    for (final bean in fileList) {
      final path = bean.path ?? "";
      if (path.isEmpty) {
        throw Exception("File path is invalid");
      }
      final file = File(path);
      if (!await file.exists()) {
        throw Exception("The file does not exist. Please select another file");
      }
      final pageCount = await FlutterPreviewFile.getPdfPageCount(path);
      if (pageCount <= 0) {
        continue;
      }
      pdfTaskList.add(_PdfExtractTask(fileInfo: bean, pageCount: pageCount));
      totalPageCount += pageCount;
    }
    if (totalPageCount <= 0) {
      throw Exception("Failed to save images");
    }
    onProgress?.call(0);
    final tempDirectory = await Directory.systemTemp.createTemp(
      "flutter_preview_gallery_",
    );
    int savedCount = 0;
    try {
      for (final task in pdfTaskList) {
        final pdfPath = task.fileInfo.path ?? "";
        for (int pageIndex = 0; pageIndex < task.pageCount; pageIndex++) {
          savedCount++;
          final outputFile = File(
            "${tempDirectory.path}/pdf_Image_${savedCount.toString().padLeft(2, "0")}.png",
          );
          if (await outputFile.exists()) {
            await outputFile.delete();
          }
          final outputPath = await FlutterPreviewFile.renderPdfPageToImage(
            pdfPath: pdfPath,
            pageIndex: pageIndex,
            outputPath: outputFile.path,
          );
          if ((outputPath ?? "").isEmpty) {
            throw Exception("Failed to save images");
          }
          final bool saved = await FlutterPreviewFile.saveImageToGallery(
            sourcePath: outputPath!,
            displayName: outputFile.uri.pathSegments.last,
            relativePath: "DCIM/Camera",
          );
          if (!saved) {
            throw Exception("Failed to save images");
          }
          onProgress?.call(savedCount / totalPageCount);
        }
      }
      return totalPageCount;
    } finally {
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    }
  }

  Future<String> queryNextScanPdfName() async {
    final outputFile = await _createSequentialOutputFile(
      prefix: "Scan",
      extension: "pdf",
    );
    return _queryFileBaseName(outputFile.uri.pathSegments.last);
  }
}

Future<void> _convertWordToPdfOoxmlIsolateEntry(
  Map<String, dynamic> message,
) async {
  final sendPort = message["sendPort"] as SendPort;
  File? outputFile;
  try {
    final rawFileInfo = message["fileInfo"];
    if (rawFileInfo is! Map) {
      throw Exception("File path is invalid");
    }
    final fileInfo = _fileInfoFromMap(Map<String, dynamic>.from(rawFileInfo));
    final path = fileInfo.path ?? "";
    if (path.isEmpty) {
      throw Exception("File path is invalid");
    }
    final sourceFile = File(path);
    if (!await sourceFile.exists()) {
      throw Exception("The file does not exist. Please select another file");
    }
    _sendTaskProgress(sendPort, 0.15);
    outputFile = await _createSequentialOutputFile(
      prefix: "word2pdf",
      extension: "pdf",
    );
    _sendTaskProgress(sendPort, 0.3);
    final rawAssetFontBytes = message["assetFontBytes"];
    final assetFontBytes = rawAssetFontBytes is Uint8List
        ? rawAssetFontBytes
        : rawAssetFontBytes is List<int>
        ? Uint8List.fromList(rawAssetFontBytes)
        : null;
    await WordToPdfConverter.convertOoxmlFileToPdf(
      inputPath: path,
      outputPath: outputFile.path,
      assetFontBytes: assetFontBytes,
    );
    _sendTaskProgress(sendPort, 0.9);
    final stat = await outputFile.stat();
    _sendTaskResult(
      sendPort,
      FileToolsFileInfo(
        name: outputFile.uri.pathSegments.last,
        type: FileToolsDocumentType.pdf,
        updateTime: stat.modified.millisecondsSinceEpoch,
        size: stat.size,
        path: outputFile.path,
      ),
    );
  } catch (e) {
    if (outputFile != null && await outputFile.exists()) {
      await outputFile.delete();
    }
    _sendTaskError(
      sendPort,
      e,
      fallbackMessage: "Failed to convert Word to PDF",
    );
  }
}

Future<FileToolsFileInfo?> _toImageFileInfo(AssetEntity entity) async {
  final file = await entity.file;
  final path = file?.path ?? "";
  if (path.isEmpty || file == null) {
    return null;
  }
  if (!await file.exists()) {
    return null;
  }
  final title = entity.title ?? await entity.titleAsync;
  final stat = await file.stat();
  return FileToolsFileInfo(
    name: title,
    updateTime: entity.modifiedDateTime.millisecondsSinceEpoch,
    size: stat.size,
    path: path,
  );
}

Future<List<Map<String, dynamic>>> _scanFileList(
  FileToolsDocumentType type,
) async {
  final List<Map<String, dynamic>> fileList = <Map<String, dynamic>>[];
  final Set<String> pathSet = <String>{};
  final roots = _querySearchRoots();
  final _AsyncScanState scanState = _AsyncScanState();
  for (final root in roots) {
    await _collectFilesFromDirectory(
      directory: root,
      targetType: type,
      fileList: fileList,
      pathSet: pathSet,
      scanState: scanState,
    );
  }
  fileList.sort(
    (a, b) => (b["updateTime"] as int).compareTo(a["updateTime"] as int),
  );
  return fileList;
}

Future<void> _collectFilesFromDirectory({
  required Directory directory,
  required FileToolsDocumentType targetType,
  required List<Map<String, dynamic>> fileList,
  required Set<String> pathSet,
  required _AsyncScanState scanState,
}) async {
  if (_shouldSkipDirectory(directory.path)) {
    return;
  }
  scanState.visitedDirectoryCount++;
  try {
    await for (final entity in directory.list(followLinks: false)) {
      scanState.visitedEntityCount++;
      if (scanState.visitedEntityCount % 200 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      if (entity is Directory) {
        await _collectFilesFromDirectory(
          directory: entity,
          targetType: targetType,
          fileList: fileList,
          pathSet: pathSet,
          scanState: scanState,
        );
        continue;
      }
      if (entity is! File) {
        continue;
      }
      final normalizedPath = entity.path;
      final fileType = _matchDocumentsType(normalizedPath);
      if (fileType == null) {
        continue;
      }
      if (targetType != FileToolsDocumentType.all && fileType != targetType) {
        continue;
      }
      if (normalizedPath.isEmpty || !pathSet.add(normalizedPath)) {
        continue;
      }
      try {
        final stat = await entity.stat();
        fileList.add(<String, dynamic>{
          "name": entity.uri.pathSegments.isEmpty
              ? entity.path
              : entity.uri.pathSegments.last,
          "typeIndex": fileType.index,
          "updateTime": stat.modified.millisecondsSinceEpoch,
          "size": stat.size,
          "path": normalizedPath,
        });
      } catch (_) {
        continue;
      }
    }
  } catch (_) {
    return;
  }
}

List<Directory> _querySearchRoots() {
  final List<Directory> roots = <Directory>[];
  final Set<String> rootPathSet = <String>{};

  void addRoot(String path) {
    if (path.isEmpty || !rootPathSet.add(path)) {
      return;
    }
    final dir = Directory(path);
    if (dir.existsSync()) {
      roots.add(dir);
    }
  }

  addRoot("/storage/emulated/0");

  return roots;
}

bool _shouldSkipDirectory(String path) {
  final normalizedPath = path.toLowerCase();
  return normalizedPath.contains("/android/data") ||
      normalizedPath.contains("/android/obb");
}

FileToolsDocumentType? _matchDocumentsType(String path) {
  final fileName = path.split("/").last;
  final dotIndex = fileName.lastIndexOf(".");
  if (dotIndex < 0 || dotIndex == fileName.length - 1) {
    return null;
  }
  final extension = fileName.substring(dotIndex + 1).toLowerCase();
  if (FileToolsService._pdfExtensions.contains(extension)) {
    return FileToolsDocumentType.pdf;
  }
  if (FileToolsService._wordExtensions.contains(extension)) {
    return FileToolsDocumentType.word;
  }
  if (FileToolsService._excelExtensions.contains(extension)) {
    return FileToolsDocumentType.excel;
  }
  return null;
}

String _queryFileExtension(String name) {
  final dotIndex = name.lastIndexOf(".");
  if (dotIndex <= 0 || dotIndex == name.length - 1) {
    return "";
  }
  return name.substring(dotIndex + 1);
}

FileToolsFileInfo _toFileInfo(Map<String, dynamic> item) {
  return FileToolsFileInfo(
    name: item["name"] as String,
    type: FileToolsDocumentType.values[item["typeIndex"] as int],
    updateTime: item["updateTime"] as int,
    size: item["size"] as int,
    path: item["path"] as String,
  );
}

Future<File> _createImagesToPdfOutputFile({String? outputFileName}) async {
  final outputDirectory = Directory("/storage/emulated/0/Files");
  if (!await outputDirectory.exists()) {
    await outputDirectory.create(recursive: true);
  }
  final customName = _sanitizeFileName(outputFileName ?? "");
  if (customName.isNotEmpty) {
    final normalizedName = customName.toLowerCase().endsWith(".pdf")
        ? customName
        : "$customName.pdf";
    final file = File("${outputDirectory.path}/$normalizedName");
    if (!await file.exists()) {
      return file;
    }
    int duplicateIndex = 1;
    final baseName = _queryFileBaseName(normalizedName);
    while (true) {
      final duplicateFile = File(
        "${outputDirectory.path}/${baseName}_${duplicateIndex.toString().padLeft(2, "0")}.pdf",
      );
      if (!await duplicateFile.exists()) {
        return duplicateFile;
      }
      duplicateIndex++;
    }
  }
  final now = DateTime.now();
  final dateText =
      "${now.year}${now.month.toString().padLeft(2, "0")}${now.day.toString().padLeft(2, "0")}";
  int index = 1;
  while (true) {
    final file = File(
      "${outputDirectory.path}/Image_${dateText}_${index.toString().padLeft(2, "0")}.pdf",
    );
    if (!await file.exists()) {
      return file;
    }
    index++;
  }
}

String _queryFileBaseName(String name) {
  final dotIndex = name.lastIndexOf(".");
  if (dotIndex <= 0) {
    return name;
  }
  return name.substring(0, dotIndex);
}

String _sanitizeEntryName(String value) {
  final sanitized = value.replaceAll(RegExp(r'[\\/:*?"<>|]+'), "_").trim();
  if (sanitized.isEmpty) {
    return "pdf";
  }
  return sanitized;
}

String _sanitizeFileName(String value) {
  return value.replaceAll(RegExp(r'[\\/:*?"<>|]+'), "_").trim();
}

Future<File> _createSequentialOutputFile({
  required String prefix,
  required String extension,
}) async {
  final outputDirectory = Directory("/storage/emulated/0/Files");
  if (!await outputDirectory.exists()) {
    await outputDirectory.create(recursive: true);
  }
  final now = DateTime.now();
  final dateText =
      "${now.year}${now.month.toString().padLeft(2, "0")}${now.day.toString().padLeft(2, "0")}";
  int index = 1;
  while (true) {
    final file = File(
      "${outputDirectory.path}/${prefix}_${dateText}_${index.toString().padLeft(2, "0")}.$extension",
    );
    if (!await file.exists()) {
      return file;
    }
    index++;
  }
}

Future<FileToolsFileInfo> _runMergePdfFilesInBackground({
  required List<FileToolsFileInfo> fileList,
  FileToolsProgressCallback? onProgress,
  FileToolsTaskControl? taskControl,
}) async {
  await taskControl?.checkpoint();
  final receivePort = ReceivePort();
  final isolate = await Isolate.spawn<Map<String, dynamic>>(
    _mergePdfFilesIsolateEntry,
    <String, dynamic>{
      "sendPort": receivePort.sendPort,
      "fileList": fileList.map(_fileInfoToMap).toList(growable: false),
    },
  );
  final completer = Completer<FileToolsFileInfo>();
  late final StreamSubscription<dynamic> subscription;
  Timer? cancelTimer;

  subscription = receivePort.listen((message) {
    if (message is! Map) {
      return;
    }
    final type = message["type"]?.toString() ?? "";
    switch (type) {
      case "progress":
        final value = message["value"];
        if (value is num) {
          onProgress?.call(value.toDouble().clamp(0, 0.99));
        }
        break;
      case "result":
        final rawFileInfo = message["fileInfo"];
        if (rawFileInfo is Map<String, dynamic>) {
          completer.complete(_fileInfoFromMap(rawFileInfo));
        } else if (rawFileInfo is Map) {
          completer.complete(
            _fileInfoFromMap(Map<String, dynamic>.from(rawFileInfo)),
          );
        } else {
          completer.completeError(Exception("Failed to merge PDF files"));
        }
        break;
      case "error":
        final messageText =
            message["message"]?.toString() ?? "Failed to merge PDF files";
        completer.completeError(Exception(messageText));
        break;
    }
  });

  cancelTimer = Timer.periodic(const Duration(milliseconds: 120), (_) {
    if (taskControl?.isCanceled == true && !completer.isCompleted) {
      completer.completeError(const FileToolsCanceledException());
    }
  });

  try {
    return await completer.future;
  } finally {
    cancelTimer.cancel();
    await subscription.cancel();
    receivePort.close();
    isolate.kill(priority: Isolate.immediate);
  }
}

Future<FileToolsFileInfo> _runFileToolsTaskInBackground({
  required Future<void> Function(Map<String, dynamic>) isolateEntry,
  required Map<String, dynamic> payload,
  required String fallbackErrorMessage,
  FileToolsProgressCallback? onProgress,
  FileToolsTaskControl? taskControl,
}) async {
  await taskControl?.checkpoint();
  final receivePort = ReceivePort();
  final isolate = await Isolate.spawn<Map<String, dynamic>>(
    isolateEntry,
    <String, dynamic>{"sendPort": receivePort.sendPort, ...payload},
  );
  final completer = Completer<FileToolsFileInfo>();
  late final StreamSubscription<dynamic> subscription;
  Timer? cancelTimer;

  subscription = receivePort.listen((message) {
    if (message is! Map) {
      return;
    }
    final type = message["type"]?.toString() ?? "";
    switch (type) {
      case "progress":
        final value = message["value"];
        if (value is num) {
          onProgress?.call(value.toDouble().clamp(0, 0.99));
        }
        break;
      case "result":
        final rawFileInfo = message["fileInfo"];
        if (completer.isCompleted) {
          return;
        }
        if (rawFileInfo is Map<String, dynamic>) {
          completer.complete(_fileInfoFromMap(rawFileInfo));
        } else if (rawFileInfo is Map) {
          completer.complete(
            _fileInfoFromMap(Map<String, dynamic>.from(rawFileInfo)),
          );
        } else {
          completer.completeError(Exception(fallbackErrorMessage));
        }
        break;
      case "error":
        if (completer.isCompleted) {
          return;
        }
        final messageText =
            message["message"]?.toString() ?? fallbackErrorMessage;
        completer.completeError(Exception(messageText));
        break;
    }
  });

  cancelTimer = Timer.periodic(const Duration(milliseconds: 120), (_) {
    if (taskControl?.isCanceled == true && !completer.isCompleted) {
      completer.completeError(const FileToolsCanceledException());
    }
  });

  try {
    return await completer.future;
  } finally {
    cancelTimer.cancel();
    await subscription.cancel();
    receivePort.close();
    isolate.kill(priority: Isolate.immediate);
  }
}

Future<void> _mergePdfFilesIsolateEntry(Map<String, dynamic> message) async {
  final sendPort = message["sendPort"] as SendPort;
  final rawFileInfoList = message["fileList"] as List<dynamic>? ?? <dynamic>[];
  PdfDocument? outputDocument;
  final List<PdfDocument> sourceDocumentList = <PdfDocument>[];
  try {
    final fileList = rawFileInfoList
        .whereType<Map>()
        .map((item) => _fileInfoFromMap(Map<String, dynamic>.from(item)))
        .toList(growable: false);
    int totalPageCount = 0;
    for (final bean in fileList) {
      final path = bean.path ?? "";
      if (path.isEmpty) {
        throw Exception("File path is invalid");
      }
      final file = File(path);
      if (!await file.exists()) {
        throw Exception("The file does not exist. Please select another file");
      }
      final sourceDocument = PdfDocument(inputBytes: await file.readAsBytes());
      sourceDocumentList.add(sourceDocument);
      totalPageCount += sourceDocument.pages.count;
    }
    if (totalPageCount <= 0) {
      throw Exception("Failed to merge PDF files");
    }
    outputDocument = PdfDocument();
    outputDocument.pageSettings.setMargins(0);
    int completedPageCount = 0;
    for (final sourceDocument in sourceDocumentList) {
      for (int index = 0; index < sourceDocument.pages.count; index++) {
        final sourcePage = sourceDocument.pages[index];
        outputDocument.pageSettings.size = sourcePage.size;
        final targetPage = outputDocument.pages.add();
        targetPage.graphics.drawPdfTemplate(
          sourcePage.createTemplate(),
          Offset.zero,
          sourcePage.size,
        );
        completedPageCount++;
        sendPort.send(<String, dynamic>{
          "type": "progress",
          "value": completedPageCount / totalPageCount,
        });
      }
    }
    final outputFile = await _createSequentialOutputFile(
      prefix: "Merge",
      extension: "pdf",
    );
    final bytes = await outputDocument.save();
    await outputFile.writeAsBytes(bytes, flush: true);
    final stat = await outputFile.stat();
    sendPort.send(<String, dynamic>{
      "type": "result",
      "fileInfo": _fileInfoToMap(
        FileToolsFileInfo(
          name: outputFile.uri.pathSegments.last,
          type: FileToolsDocumentType.pdf,
          updateTime: stat.modified.millisecondsSinceEpoch,
          size: stat.size,
          path: outputFile.path,
        ),
      ),
    });
  } catch (e) {
    _sendTaskError(sendPort, e, fallbackMessage: "Failed to merge PDF files");
  } finally {
    for (final document in sourceDocumentList) {
      document.dispose();
    }
    outputDocument?.dispose();
  }
}

Future<void> _splitPdfFileIsolateEntry(Map<String, dynamic> message) async {
  final sendPort = message["sendPort"] as SendPort;
  PdfDocument? sourceDocument;
  PdfDocument? outputDocument;
  try {
    final rawFileInfo = message["fileInfo"];
    final rawPageIndexList =
        message["selectedPageIndexList"] as List<dynamic>? ?? <dynamic>[];
    if (rawFileInfo is! Map) {
      throw Exception("File path is invalid");
    }
    final fileInfo = _fileInfoFromMap(Map<String, dynamic>.from(rawFileInfo));
    final selectedPageIndexList = rawPageIndexList
        .whereType<num>()
        .map((item) => item.toInt())
        .toList(growable: false);
    if (selectedPageIndexList.isEmpty) {
      throw Exception("Please select at least one page");
    }
    final path = fileInfo.path ?? "";
    if (path.isEmpty) {
      throw Exception("File path is invalid");
    }
    final file = File(path);
    if (!await file.exists()) {
      throw Exception("The file does not exist. Please select another file");
    }
    sourceDocument = PdfDocument(inputBytes: await file.readAsBytes());
    final totalPageCount = sourceDocument.pages.count;
    final normalizedPageIndexList = <int>[];
    for (final index in selectedPageIndexList) {
      if (index >= 0 && index < totalPageCount) {
        normalizedPageIndexList.add(index);
      }
    }
    if (normalizedPageIndexList.isEmpty) {
      throw Exception("Please select at least one valid page");
    }
    outputDocument = PdfDocument();
    outputDocument.pageSettings.setMargins(0);
    for (int i = 0; i < normalizedPageIndexList.length; i++) {
      final sourcePage = sourceDocument.pages[normalizedPageIndexList[i]];
      outputDocument.pageSettings.size = sourcePage.size;
      final targetPage = outputDocument.pages.add();
      targetPage.graphics.drawPdfTemplate(
        sourcePage.createTemplate(),
        Offset.zero,
        sourcePage.size,
      );
      _sendTaskProgress(sendPort, (i + 1) / normalizedPageIndexList.length);
    }
    final outputFile = await _createSequentialOutputFile(
      prefix: "split",
      extension: "pdf",
    );
    final bytes = await outputDocument.save();
    await outputFile.writeAsBytes(bytes, flush: true);
    final stat = await outputFile.stat();
    _sendTaskResult(
      sendPort,
      FileToolsFileInfo(
        name: outputFile.uri.pathSegments.last,
        type: FileToolsDocumentType.pdf,
        updateTime: stat.modified.millisecondsSinceEpoch,
        size: stat.size,
        path: outputFile.path,
      ),
    );
  } catch (e) {
    _sendTaskError(sendPort, e, fallbackMessage: "Failed to split PDF");
  } finally {
    sourceDocument?.dispose();
    outputDocument?.dispose();
  }
}

Future<void> _extractPdfTextFileIsolateEntry(
  Map<String, dynamic> message,
) async {
  final sendPort = message["sendPort"] as SendPort;
  File? outputFile;
  try {
    final rawFileInfo = message["fileInfo"];
    final rawPageIndexList =
        message["selectedPageIndexList"] as List<dynamic>? ?? <dynamic>[];
    if (rawFileInfo is! Map) {
      throw Exception("File path is invalid");
    }
    final fileInfo = _fileInfoFromMap(Map<String, dynamic>.from(rawFileInfo));
    final selectedPageIndexList = rawPageIndexList
        .whereType<num>()
        .map((item) => item.toInt())
        .toList(growable: false);
    final path = fileInfo.path ?? "";
    if (path.isEmpty) {
      throw Exception("File path is invalid");
    }
    final sourceFile = File(path);
    if (!await sourceFile.exists()) {
      throw Exception("The file does not exist. Please select another file");
    }
    if (selectedPageIndexList.isEmpty) {
      throw Exception("Please select at least one page");
    }
    outputFile = await _createSequentialOutputFile(
      prefix: "ExtractText",
      extension: "txt",
    );
    final text = await FlutterPreviewFile.extractPdfText(
      inputPath: path,
      selectedPageIndexList: selectedPageIndexList,
      onProgress: (progress) {
        _sendTaskProgress(sendPort, progress);
      },
    );
    await outputFile.writeAsString(text, flush: true);
    final stat = await outputFile.stat();
    _sendTaskResult(
      sendPort,
      FileToolsFileInfo(
        name: outputFile.uri.pathSegments.last,
        type: FileToolsDocumentType.word,
        updateTime: stat.modified.millisecondsSinceEpoch,
        size: stat.size,
        path: outputFile.path,
      ),
    );
  } catch (e) {
    if (outputFile != null && await outputFile.exists()) {
      await outputFile.delete();
    }
    _sendTaskError(sendPort, e, fallbackMessage: "Failed to extract text");
  }
}

Future<void> _generatePdfFromImagesIsolateEntry(
  Map<String, dynamic> message,
) async {
  final sendPort = message["sendPort"] as SendPort;
  PdfDocument? outputDocument;
  try {
    final rawImageList = message["imageList"] as List<dynamic>? ?? <dynamic>[];
    final outputFileName = message["outputFileName"]?.toString();
    final imageList = rawImageList
        .whereType<Map>()
        .map((item) => _fileInfoFromMap(Map<String, dynamic>.from(item)))
        .toList(growable: false);
    if (imageList.isEmpty) {
      throw Exception("Please select at least one image");
    }
    outputDocument = PdfDocument();
    outputDocument.pageSettings.setMargins(0);
    final totalCount = imageList.length;
    for (int index = 0; index < totalCount; index++) {
      final bean = imageList[index];
      final path = bean.path ?? "";
      if (path.isEmpty) {
        throw Exception("Image path is invalid");
      }
      final file = File(path);
      if (!await file.exists()) {
        throw Exception(
          "The image does not exist. Please select another image",
        );
      }
      final imageBytes = await file.readAsBytes();
      final bitmap = PdfBitmap(imageBytes);
      outputDocument.pageSettings
        ..orientation = bitmap.width >= bitmap.height
            ? PdfPageOrientation.landscape
            : PdfPageOrientation.portrait
        ..size = PdfPageSize.a4;
      final page = outputDocument.pages.add();
      final clientSize = page.getClientSize();
      final imageWidth = bitmap.width.toDouble();
      final imageHeight = bitmap.height.toDouble();
      final scale = math.min(
        clientSize.width / imageWidth,
        clientSize.height / imageHeight,
      );
      final drawWidth = imageWidth * scale;
      final drawHeight = imageHeight * scale;
      page.graphics.drawImage(
        bitmap,
        Rect.fromLTWH(
          (clientSize.width - drawWidth) / 2,
          (clientSize.height - drawHeight) / 2,
          drawWidth,
          drawHeight,
        ),
      );
      _sendTaskProgress(sendPort, (index + 1) / totalCount);
    }
    final outputFile = await _createImagesToPdfOutputFile(
      outputFileName: outputFileName,
    );
    final bytes = await outputDocument.save();
    await outputFile.writeAsBytes(bytes, flush: true);
    final stat = await outputFile.stat();
    _sendTaskResult(
      sendPort,
      FileToolsFileInfo(
        name: outputFile.uri.pathSegments.last,
        type: FileToolsDocumentType.pdf,
        updateTime: stat.modified.millisecondsSinceEpoch,
        size: stat.size,
        path: outputFile.path,
      ),
    );
  } catch (e) {
    _sendTaskError(sendPort, e, fallbackMessage: "Failed to generate PDF");
  } finally {
    outputDocument?.dispose();
  }
}

Future<void> _generatePdfFromImagesAndroidIsolateEntry(
  Map<String, dynamic> message,
) async {
  final sendPort = message["sendPort"] as SendPort;
  final rootIsolateToken = message["rootIsolateToken"] as RootIsolateToken?;
  try {
    if (rootIsolateToken == null) {
      throw Exception("Root isolate token is invalid");
    }
    BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);
    final rawImageList = message["imageList"] as List<dynamic>? ?? <dynamic>[];
    final outputPath = message["outputPath"]?.toString() ?? "";
    final imageList = rawImageList
        .whereType<Map>()
        .map((item) => _fileInfoFromMap(Map<String, dynamic>.from(item)))
        .toList(growable: false);
    if (imageList.isEmpty) {
      throw Exception("Please select at least one image");
    }
    if (outputPath.isEmpty) {
      throw Exception("Output path is invalid");
    }
    await FlutterPreviewFilePlatform.instance.generatePdfFromImages(
      imageList: imageList.map(_fileInfoToMap).toList(growable: false),
      outputPath: outputPath,
    );
    final outputFile = File(outputPath);
    if (!await outputFile.exists()) {
      throw Exception("Failed to generate PDF");
    }
    final stat = await outputFile.stat();
    _sendTaskResult(
      sendPort,
      FileToolsFileInfo(
        name: outputFile.uri.pathSegments.last,
        type: FileToolsDocumentType.pdf,
        updateTime: stat.modified.millisecondsSinceEpoch,
        size: stat.size,
        path: outputFile.path,
      ),
    );
  } catch (e) {
    _sendTaskError(sendPort, e, fallbackMessage: "Failed to generate PDF");
  }
}

void _sendTaskProgress(SendPort sendPort, double progress) {
  sendPort.send(<String, dynamic>{
    "type": "progress",
    "value": progress.clamp(0, 1),
  });
}

void _sendTaskResult(SendPort sendPort, FileToolsFileInfo fileInfo) {
  sendPort.send(<String, dynamic>{
    "type": "result",
    "fileInfo": _fileInfoToMap(fileInfo),
  });
}

void _sendTaskError(
  SendPort sendPort,
  Object error, {
  required String fallbackMessage,
}) {
  final message = error.toString().replaceFirst("Exception: ", "").trim();
  sendPort.send(<String, dynamic>{
    "type": "error",
    "message": message.isEmpty ? fallbackMessage : message,
  });
}

Map<String, dynamic> _fileInfoToMap(FileToolsFileInfo item) {
  return <String, dynamic>{
    "name": item.name,
    "typeIndex": item.type?.index,
    "updateTime": item.updateTime,
    "size": item.size,
    "path": item.path,
    "bookmark": item.bookmark,
  };
}

FileToolsFileInfo _fileInfoFromMap(Map<String, dynamic> item) {
  final rawTypeIndex = item["typeIndex"];
  return FileToolsFileInfo(
    name: item["name"] as String?,
    type: rawTypeIndex is int
        ? FileToolsDocumentType.values[rawTypeIndex]
        : null,
    updateTime: item["updateTime"] as int?,
    size: item["size"] as int?,
    path: item["path"] as String?,
    bookmark: item["bookmark"] as bool?,
  );
}

class _PdfExtractTask {
  _PdfExtractTask({required this.fileInfo, required this.pageCount});

  final FileToolsFileInfo fileInfo;
  final int pageCount;
}

class _AsyncScanState {
  int visitedDirectoryCount = 0;
  int visitedEntityCount = 0;
}
