import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../common/preview_builders.dart';
import '../common/preview_placeholder.dart';
import 'excel_file_controller.dart';

class ExcelFileView extends StatefulWidget {
  const ExcelFileView({
    super.key,
    required this.controller,
    this.autoInitialize = true,
    this.padding = const EdgeInsets.all(16),
    this.loadingBuilder,
    this.messageBuilder,
    this.sheetTabPadding = const EdgeInsets.symmetric(
      horizontal: 16,
      vertical: 12,
    ),
  });

  final ExcelFileController controller;
  final bool autoInitialize;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry sheetTabPadding;
  final PreviewLoadingBuilder? loadingBuilder;
  final PreviewMessageBuilder? messageBuilder;

  @override
  State<ExcelFileView> createState() => _ExcelFileViewState();
}

class _ExcelFileViewState extends State<ExcelFileView> {
  @override
  void initState() {
    super.initState();
    if (widget.autoInitialize) {
      widget.controller.initialize();
    }
  }

  @override
  void didUpdateWidget(covariant ExcelFileView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.autoInitialize && oldWidget.controller != widget.controller) {
      widget.controller.initialize();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        if (controller.loading) {
          return widget.loadingBuilder?.call(context) ??
              const Center(child: CircularProgressIndicator());
        }
        if (!controller.fileExists) {
          return _buildMessage(
            context,
            'The source file is no longer available.',
          );
        }
        if (controller.errorText.isNotEmpty) {
          return _buildMessage(context, controller.errorText);
        }

        return Column(
          children: [
            if (controller.showSheetTabs) _buildSheetTabs(context, controller),
            Expanded(child: _buildBody(context, controller)),
          ],
        );
      },
    );
  }

  Widget _buildSheetTabs(BuildContext context, ExcelFileController controller) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: widget.sheetTabPadding,
      color: theme.colorScheme.surface,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: controller.sheetNameList.map((sheetName) {
            final selected = sheetName == controller.currentSheetName;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () {
                  controller.selectSheet(sheetName);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? theme.colorScheme.primary.withValues(alpha: 0.12)
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    sheetName,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, ExcelFileController controller) {
    final webViewController = controller.isEditing
        ? controller.htmlEditorController
        : controller.htmlPreviewController;
    if (controller.preparingSheet || webViewController == null) {
      return widget.loadingBuilder?.call(context) ??
          const Center(child: CircularProgressIndicator());
    }
    return Padding(
      padding: widget.padding,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: WebViewWidget(controller: webViewController),
      ),
    );
  }

  Widget _buildMessage(BuildContext context, String message) {
    return widget.messageBuilder?.call(context, message) ??
        PreviewPlaceholder(message: message);
  }
}
