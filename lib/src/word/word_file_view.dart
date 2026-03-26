import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../common/preview_builders.dart';
import '../common/preview_placeholder.dart';
import 'word_file_controller.dart';

class WordFileView extends StatefulWidget {
  const WordFileView({
    super.key,
    required this.controller,
    this.autoInitialize = true,
    this.padding = const EdgeInsets.all(16),
    this.loadingBuilder,
    this.messageBuilder,
    this.editorDecoration,
    this.previewDecoration,
  });

  final WordFileController controller;
  final bool autoInitialize;
  final EdgeInsetsGeometry padding;
  final PreviewLoadingBuilder? loadingBuilder;
  final PreviewMessageBuilder? messageBuilder;
  final BoxDecoration? editorDecoration;
  final BoxDecoration? previewDecoration;

  @override
  State<WordFileView> createState() => _WordFileViewState();
}

class _WordFileViewState extends State<WordFileView> {
  @override
  void initState() {
    super.initState();
    if (widget.autoInitialize) {
      widget.controller.initialize();
    }
  }

  @override
  void didUpdateWidget(covariant WordFileView oldWidget) {
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
        if (controller.isEditing) {
          return _buildEditing(context, controller);
        }
        return _buildPreview(context, controller);
      },
    );
  }

  Widget _buildEditing(BuildContext context, WordFileController controller) {
    if (controller.isHtmlEditable) {
      if (controller.preparingHtmlEditor ||
          controller.htmlEditorController == null) {
        return widget.loadingBuilder?.call(context) ??
            const Center(child: CircularProgressIndicator());
      }
      return Padding(
        padding: widget.padding,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: DecoratedBox(
            decoration:
                widget.editorDecoration ?? _defaultBoxDecoration(context),
            child: WebViewWidget(controller: controller.htmlEditorController!),
          ),
        ),
      );
    }
    return Padding(
      padding: widget.padding,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: DecoratedBox(
          decoration: widget.editorDecoration ?? _defaultBoxDecoration(context),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: TextField(
              controller: controller.textEditingController,
              focusNode: controller.textFocusNode,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                border: InputBorder.none,
                hintText: 'Please enter content',
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPreview(BuildContext context, WordFileController controller) {
    if (controller.isHtmlEditable) {
      if (controller.preparingHtmlPreview ||
          controller.htmlPreviewController == null) {
        return widget.loadingBuilder?.call(context) ??
            const Center(child: CircularProgressIndicator());
      }
      return Padding(
        padding: widget.padding,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: DecoratedBox(
            decoration:
                widget.previewDecoration ?? _defaultBoxDecoration(context),
            child: WebViewWidget(controller: controller.htmlPreviewController!),
          ),
        ),
      );
    }
    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: SingleChildScrollView(
        padding: widget.padding,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: DecoratedBox(
            decoration:
                widget.previewDecoration ?? _defaultBoxDecoration(context),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Html(
                data: controller.htmlText,
                style: {
                  'body': Style(
                    margin: Margins.zero,
                    padding: HtmlPaddings.zero,
                    lineHeight: const LineHeight(1.5),
                  ),
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  BoxDecoration _defaultBoxDecoration(BuildContext context) {
    return BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Theme.of(context).dividerColor),
    );
  }

  Widget _buildMessage(BuildContext context, String message) {
    return widget.messageBuilder?.call(context, message) ??
        PreviewPlaceholder(message: message);
  }
}
