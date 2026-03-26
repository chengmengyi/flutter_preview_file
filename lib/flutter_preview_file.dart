import 'flutter_preview_file_platform_interface.dart';
import 'dart:typed_data';
import 'src/file_tools_models.dart';
import 'src/file_tools_service.dart';
import 'src/file_tools_task_control.dart';
import 'src/pdf/pdf_to_word_converter.dart';
import 'src/word/word_to_pdf_converter.dart';

export 'package:archive/archive_io.dart' show ZipFileEncoder;
export 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart'
    show
        Annotation,
        HighlightAnnotation,
        PdfPageChangedDetails,
        PdfPageLayoutMode,
        PdfAnnotationMode,
        PdfDocumentLoadFailedDetails,
        PdfDocumentLoadedDetails,
        PdfTextLine,
        PdfTextSelectionChangedDetails,
        SfPdfViewerState,
        StrikethroughAnnotation,
        UnderlineAnnotation,
        PdfViewerController;
export 'package:syncfusion_flutter_pdf/pdf.dart'
    show
        PdfBitmap,
        PdfColor,
        PdfDocument,
        PdfPageOrientation,
        PdfPageSize,
        PdfPath,
        PdfPen;
export 'src/common/preview_builders.dart';
export 'src/excel/excel_file_controller.dart';
export 'src/excel/excel_file_view.dart';
export 'src/file_tools_models.dart';
export 'src/file_tools_service.dart' show FileToolsProgressCallback;
export 'src/file_tools_task_control.dart';
export 'src/pdf/pdf_file_view.dart';
export 'src/word/word_file_controller.dart';
export 'src/word/word_file_view.dart';

class FlutterPreviewFile {
  const FlutterPreviewFile._();

  static Future<String?> getPlatformVersion() {
    return FlutterPreviewFilePlatform.instance.getPlatformVersion();
  }

  static Future<Map<String, dynamic>?> loadDocContent(String path) {
    return FlutterPreviewFilePlatform.instance.loadDocContent(path);
  }

  static Future<String?> convertDocToHtml(String path) {
    return FlutterPreviewFilePlatform.instance.convertDocToHtml(path);
  }

  static Future<String?> convertHtmlToPdf({
    required String html,
    required String outputPath,
  }) {
    return FlutterPreviewFilePlatform.instance.convertHtmlToPdf(
      html: html,
      outputPath: outputPath,
    );
  }

  static Future<String> convertWordToPdf({
    required String inputPath,
    required String outputPath,
  }) {
    return WordToPdfConverter.convert(
      inputPath: inputPath,
      outputPath: outputPath,
    );
  }

  static Future<String> convertPdfToWord({
    required String inputPath,
    required String outputPath,
    List<int>? selectedPageIndexList,
    void Function(double progress)? onProgress,
  }) {
    return PdfToWordConverter.convert(
      inputPath: inputPath,
      outputPath: outputPath,
      selectedPageIndexList: selectedPageIndexList,
      onProgress: onProgress,
    );
  }

  static Future<String> extractPdfText({
    required String inputPath,
    List<int>? selectedPageIndexList,
    void Function(double progress)? onProgress,
  }) {
    return PdfToWordConverter.extractText(
      inputPath: inputPath,
      selectedPageIndexList: selectedPageIndexList,
      onProgress: onProgress,
    );
  }

  static Future<bool> saveDocTextContent({
    required String path,
    required String text,
  }) {
    return FlutterPreviewFilePlatform.instance.saveDocTextContent(
      path: path,
      text: text,
    );
  }

  static Future<void> scanFile(String path) {
    return FlutterPreviewFilePlatform.instance.scanFile(path);
  }

  static Future<int> getPdfPageCount(String path) {
    return FlutterPreviewFilePlatform.instance.getPdfPageCount(path);
  }

  static Future<String?> renderPdfPageToImage({
    required String pdfPath,
    required int pageIndex,
    required String outputPath,
    int? width,
  }) {
    return FlutterPreviewFilePlatform.instance.renderPdfPageToImage(
      pdfPath: pdfPath,
      pageIndex: pageIndex,
      outputPath: outputPath,
      width: width,
    );
  }

  static Future<Uint8List?> renderPdfPageToImageBytes({
    required String pdfPath,
    required int pageIndex,
    int? width,
  }) {
    return FlutterPreviewFilePlatform.instance.renderPdfPageToImageBytes(
      pdfPath: pdfPath,
      pageIndex: pageIndex,
      width: width,
    );
  }

  static Future<List<FileToolsFileInfo>> queryFileList(
    FileToolsDocumentType type,
  ) {
    return FileToolsService.instance.queryFileList(type);
  }

  static FileToolsDocumentType? matchDocumentsType(String path) {
    return FileToolsService.instance.matchDocumentsType(path);
  }

  static Future<FileToolsFileInfo?> renameFile({
    required FileToolsFileInfo fileInfo,
    required String newNameWithoutExtension,
  }) {
    return FileToolsService.instance.renameFile(
      fileInfo: fileInfo,
      newNameWithoutExtension: newNameWithoutExtension,
    );
  }

  static Future<bool> deleteFile(String path) {
    return FileToolsService.instance.deleteFile(path);
  }

  static Future<bool> fileExists(String path) {
    return FileToolsService.instance.fileExists(path);
  }

  static List<FileToolsFileInfo> sortFileList(
    List<FileToolsFileInfo> fileList,
    FileToolsSortType sortType,
  ) {
    return FileToolsService.instance.sortFileList(fileList, sortType);
  }

  static Future<FileToolsFileInfo> mergePdfFiles({
    required List<FileToolsFileInfo> fileList,
    FileToolsProgressCallback? onProgress,
    FileToolsTaskControl? taskControl,
  }) {
    return FileToolsService.instance.mergePdfFiles(
      fileList: fileList,
      onProgress: onProgress,
      taskControl: taskControl,
    );
  }

  static Future<FileToolsFileInfo> splitPdfFile({
    required FileToolsFileInfo fileInfo,
    required List<int> selectedPageIndexList,
    FileToolsProgressCallback? onProgress,
    FileToolsTaskControl? taskControl,
  }) {
    return FileToolsService.instance.splitPdfFile(
      fileInfo: fileInfo,
      selectedPageIndexList: selectedPageIndexList,
      onProgress: onProgress,
      taskControl: taskControl,
    );
  }

  static Future<FileToolsFileInfo> convertWordToPdfFile({
    required FileToolsFileInfo fileInfo,
    FileToolsProgressCallback? onProgress,
    FileToolsTaskControl? taskControl,
  }) {
    return FileToolsService.instance.convertWordToPdfFile(
      fileInfo: fileInfo,
      onProgress: onProgress,
      taskControl: taskControl,
    );
  }

  static Future<FileToolsFileInfo> convertPdfToWordFile({
    required FileToolsFileInfo fileInfo,
    FileToolsProgressCallback? onProgress,
    FileToolsTaskControl? taskControl,
  }) {
    return FileToolsService.instance.convertPdfToWordFile(
      fileInfo: fileInfo,
      onProgress: onProgress,
      taskControl: taskControl,
    );
  }

  static Future<FileToolsFileInfo> extractPdfTextFile({
    required FileToolsFileInfo fileInfo,
    required List<int> selectedPageIndexList,
    FileToolsProgressCallback? onProgress,
    FileToolsTaskControl? taskControl,
  }) {
    return FileToolsService.instance.extractPdfTextFile(
      fileInfo: fileInfo,
      selectedPageIndexList: selectedPageIndexList,
      onProgress: onProgress,
      taskControl: taskControl,
    );
  }

  static Future<List<FileToolsFileInfo>> queryAllImages() {
    return FileToolsService.instance.queryAllImages();
  }

  static Future<FileToolsFileInfo> generatePdfFromImages({
    required List<FileToolsFileInfo> imageList,
    String? outputFileName,
    FileToolsProgressCallback? onProgress,
    FileToolsTaskControl? taskControl,
  }) {
    return FileToolsService.instance.generatePdfFromImages(
      imageList: imageList,
      outputFileName: outputFileName,
      onProgress: onProgress,
      taskControl: taskControl,
    );
  }

  static Future<FileToolsPdfToImagesZipResult> extractPdfToImagesZip({
    required List<FileToolsFileInfo> fileList,
    FileToolsProgressCallback? onProgress,
    FileToolsTaskControl? taskControl,
  }) {
    return FileToolsService.instance.extractPdfToImagesZip(
      fileList: fileList,
      onProgress: onProgress,
      taskControl: taskControl,
    );
  }

  static Future<int> savePdfImagesToGallery({
    required List<FileToolsFileInfo> fileList,
    FileToolsProgressCallback? onProgress,
  }) {
    return FileToolsService.instance.savePdfImagesToGallery(
      fileList: fileList,
      onProgress: onProgress,
    );
  }

  static Future<Uint8List?> queryPdfImage({
    required FileToolsFileInfo fileInfo,
    required int pageIndex,
    int? width,
  }) {
    return FileToolsService.instance.queryPdfImage(
      fileInfo: fileInfo,
      pageIndex: pageIndex,
      width: width,
    );
  }

  static Future<String> queryNextScanPdfName() {
    return FileToolsService.instance.queryNextScanPdfName();
  }
}
