import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_preview_file_platform_interface.dart';

/// An implementation of [FlutterPreviewFilePlatform] that uses method channels.
class MethodChannelFlutterPreviewFile extends FlutterPreviewFilePlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_preview_file');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }

  @override
  Future<Map<String, dynamic>?> loadDocContent(String path) {
    return methodChannel.invokeMapMethod<String, dynamic>('loadDocContent', {
      'path': path,
    });
  }

  @override
  Future<String?> convertDocToHtml(String path) {
    return methodChannel.invokeMethod<String>('convertDocToHtml', {
      'path': path,
    });
  }

  @override
  Future<String?> convertHtmlToPdf({
    required String html,
    required String outputPath,
  }) {
    return methodChannel.invokeMethod<String>('convertHtmlToPdf', {
      'html': html,
      'outputPath': outputPath,
    });
  }

  @override
  Future<bool> saveDocTextContent({
    required String path,
    required String text,
  }) async {
    final value = await methodChannel.invokeMethod<bool>('saveDocTextContent', {
      'path': path,
      'text': text,
    });
    return value ?? false;
  }

  @override
  Future<void> scanFile(String path) async {
    await methodChannel.invokeMethod<void>('scanFile', {'path': path});
  }

  @override
  Future<bool> saveImageToGallery({
    required String sourcePath,
    required String displayName,
    String? relativePath,
  }) async {
    final bool? value = await methodChannel
        .invokeMethod<bool>('saveImageToGallery', <String, dynamic>{
          'sourcePath': sourcePath,
          'displayName': displayName,
          'relativePath': relativePath,
        });
    return value ?? false;
  }

  @override
  Future<int> getPdfPageCount(String path) async {
    final value = await methodChannel.invokeMethod<int>('getPdfPageCount', {
      'path': path,
    });
    return value ?? 0;
  }

  @override
  Future<String?> renderPdfPageToImage({
    required String pdfPath,
    required int pageIndex,
    required String outputPath,
    int? width,
  }) {
    return methodChannel.invokeMethod<String>('renderPdfPageToImage', {
      'pdfPath': pdfPath,
      'pageIndex': pageIndex,
      'outputPath': outputPath,
      'width': width,
    });
  }

  @override
  Future<Uint8List?> renderPdfPageToImageBytes({
    required String pdfPath,
    required int pageIndex,
    int? width,
  }) {
    return methodChannel.invokeMethod<Uint8List>('renderPdfPageToImageBytes', {
      'pdfPath': pdfPath,
      'pageIndex': pageIndex,
      'width': width,
    });
  }
}
