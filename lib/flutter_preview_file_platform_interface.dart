import 'dart:typed_data';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_preview_file_method_channel.dart';

abstract class FlutterPreviewFilePlatform extends PlatformInterface {
  /// Constructs a FlutterPreviewFilePlatform.
  FlutterPreviewFilePlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterPreviewFilePlatform _instance =
      MethodChannelFlutterPreviewFile();

  /// The default instance of [FlutterPreviewFilePlatform] to use.
  ///
  /// Defaults to [MethodChannelFlutterPreviewFile].
  static FlutterPreviewFilePlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FlutterPreviewFilePlatform] when
  /// they register themselves.
  static set instance(FlutterPreviewFilePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  Future<Map<String, dynamic>?> loadDocContent(String path) {
    throw UnimplementedError('loadDocContent() has not been implemented.');
  }

  Future<String?> convertDocToHtml(String path) {
    throw UnimplementedError('convertDocToHtml() has not been implemented.');
  }

  Future<String?> convertHtmlToPdf({
    required String html,
    required String outputPath,
  }) {
    throw UnimplementedError('convertHtmlToPdf() has not been implemented.');
  }

  Future<String?> generatePdfFromImages({
    required List<Map<String, dynamic>> imageList,
    required String outputPath,
    int? maxSidePx,
  }) {
    throw UnimplementedError(
      'generatePdfFromImages() has not been implemented.',
    );
  }

  Future<bool> saveDocTextContent({
    required String path,
    required String text,
  }) {
    throw UnimplementedError('saveDocTextContent() has not been implemented.');
  }

  Future<void> scanFile(String path) {
    throw UnimplementedError('scanFile() has not been implemented.');
  }

  Future<bool> saveImageToGallery({
    required String sourcePath,
    required String displayName,
    String? relativePath,
  }) {
    throw UnimplementedError('saveImageToGallery() has not been implemented.');
  }

  Future<int> getPdfPageCount(String path) {
    throw UnimplementedError('getPdfPageCount() has not been implemented.');
  }

  Future<String?> renderPdfPageToImage({
    required String pdfPath,
    required int pageIndex,
    required String outputPath,
    int? width,
  }) {
    throw UnimplementedError(
      'renderPdfPageToImage() has not been implemented.',
    );
  }

  Future<Uint8List?> renderPdfPageToImageBytes({
    required String pdfPath,
    required int pageIndex,
    int? width,
  }) {
    throw UnimplementedError(
      'renderPdfPageToImageBytes() has not been implemented.',
    );
  }
}
