import 'dart:io';

import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import '../common/preview_builders.dart';
import '../common/preview_placeholder.dart';

class PdfFileView extends StatelessWidget {
  const PdfFileView({
    super.key,
    required this.filePath,
    this.viewerKey,
    this.controller,
    this.undoController,
    this.loadingBuilder,
    this.messageBuilder,
    this.canShowPaginationDialog = false,
    this.canShowScrollHead = false,
    this.canShowScrollStatus = false,
    this.enableTextSelection = true,
    this.canShowTextSelectionMenu = true,
    this.pageLayoutMode = PdfPageLayoutMode.continuous,
    this.onDocumentLoaded,
    this.onDocumentLoadFailed,
    this.onTextSelectionChanged,
    this.onPageChanged,
    this.onAnnotationAdded,
    this.onAnnotationRemoved,
    this.onAnnotationEdited,
    this.onTap,
  });

  final String filePath;
  final GlobalKey<SfPdfViewerState>? viewerKey;
  final PdfViewerController? controller;
  final UndoHistoryController? undoController;
  final PreviewLoadingBuilder? loadingBuilder;
  final PreviewMessageBuilder? messageBuilder;
  final bool canShowPaginationDialog;
  final bool canShowScrollHead;
  final bool canShowScrollStatus;
  final bool enableTextSelection;
  final bool canShowTextSelectionMenu;
  final PdfPageLayoutMode pageLayoutMode;
  final PdfDocumentLoadedCallback? onDocumentLoaded;
  final PdfDocumentLoadFailedCallback? onDocumentLoadFailed;
  final PdfTextSelectionChangedCallback? onTextSelectionChanged;
  final PdfPageChangedCallback? onPageChanged;
  final PdfAnnotationCallback? onAnnotationAdded;
  final PdfAnnotationCallback? onAnnotationRemoved;
  final PdfAnnotationCallback? onAnnotationEdited;
  final PdfGestureTapCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (filePath.isEmpty) {
      return _buildMessage(context, 'File path is empty.');
    }
    final file = File(filePath);
    if (!file.existsSync()) {
      return _buildMessage(context, 'The source file is no longer available.');
    }
    return SfPdfViewer.file(
      key: viewerKey,
      file,
      controller: controller,
      undoController: undoController,
      canShowPaginationDialog: canShowPaginationDialog,
      canShowScrollHead: canShowScrollHead,
      canShowScrollStatus: canShowScrollStatus,
      enableTextSelection: enableTextSelection,
      canShowTextSelectionMenu: canShowTextSelectionMenu,
      pageLayoutMode: pageLayoutMode,
      onDocumentLoaded: onDocumentLoaded,
      onDocumentLoadFailed: onDocumentLoadFailed,
      onTextSelectionChanged: onTextSelectionChanged,
      onPageChanged: onPageChanged,
      onAnnotationAdded: onAnnotationAdded,
      onAnnotationRemoved: onAnnotationRemoved,
      onAnnotationEdited: onAnnotationEdited,
      onTap: onTap,
    );
  }

  Widget _buildMessage(BuildContext context, String message) {
    return messageBuilder?.call(context, message) ??
        PreviewPlaceholder(message: message);
  }
}
