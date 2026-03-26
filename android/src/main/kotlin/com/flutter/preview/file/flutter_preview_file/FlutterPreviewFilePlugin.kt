package com.flutter.preview.file.flutter_preview_file

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.pdf.PdfDocument
import android.graphics.pdf.PdfRenderer
import android.media.MediaScannerConnection
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.webkit.MimeTypeMap
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import org.apache.poi.hwpf.HWPFDocument
import org.apache.poi.hwpf.converter.WordToHtmlConverter
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.ByteArrayOutputStream
import java.io.StringWriter
import java.nio.charset.Charset
import java.nio.charset.StandardCharsets
import javax.xml.parsers.DocumentBuilderFactory
import javax.xml.transform.OutputKeys
import javax.xml.transform.TransformerFactory
import javax.xml.transform.dom.DOMSource
import javax.xml.transform.stream.StreamResult

class FlutterPreviewFilePlugin : FlutterPlugin, MethodCallHandler, ActivityAware {
    companion object {
        private const val TAG = "FlutterPreviewFile"
        private const val PDF_PAGE_WIDTH = 595
        private const val PDF_PAGE_HEIGHT = 842
    }

    private lateinit var channel: MethodChannel
    private lateinit var binding: FlutterPlugin.FlutterPluginBinding
    private var activity: Activity? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        binding = flutterPluginBinding
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "flutter_preview_file")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getPlatformVersion" -> result.success("Android ${android.os.Build.VERSION.RELEASE}")

            "loadDocContent" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.error("invalid_path", "File path is empty", null)
                    return
                }
                try {
                    result.success(loadDocContent(path))
                } catch (e: Exception) {
                    result.error(
                        "convert_failed",
                        e.message ?: "Failed to load doc content",
                        null,
                    )
                }
            }

            "convertDocToHtml" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.error("invalid_path", "File path is empty", null)
                    return
                }
                try {
                    result.success(convertDocToHtml(path))
                } catch (e: Exception) {
                    result.error(
                        "convert_failed",
                        e.message ?: "Failed to convert doc to html",
                        null,
                    )
                }
            }

            "convertHtmlToPdf" -> {
                val html = call.argument<String>("html")
                val outputPath = call.argument<String>("outputPath")
                if (html.isNullOrEmpty() || outputPath.isNullOrEmpty()) {
                    result.error("invalid_args", "Html convert arguments are invalid", null)
                    return
                }
                try {
                    convertHtmlToPdf(html, outputPath, result)
                } catch (e: Exception) {
                    result.error(
                        "convert_pdf_failed",
                        e.message ?: "Failed to convert html to pdf",
                        null,
                    )
                }
            }

            "saveDocTextContent" -> {
                val path = call.argument<String>("path")
                val text = call.argument<String>("text")
                if (path.isNullOrEmpty()) {
                    result.error("invalid_path", "File path is empty", null)
                    return
                }
                try {
                    saveDocTextContent(path, text ?: "")
                    result.success(true)
                } catch (e: Exception) {
                    result.error(
                        "save_failed",
                        e.message ?: "Failed to save doc content",
                        null,
                    )
                }
            }

            "scanFile" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.error("invalid_path", "File path is empty", null)
                    return
                }
                try {
                    scanFile(path, result)
                } catch (e: Exception) {
                    result.error(
                        "scan_failed",
                        e.message ?: "Failed to scan file",
                        null,
                    )
                }
            }

            "getPdfPageCount" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.error("invalid_path", "File path is empty", null)
                    return
                }
                try {
                    result.success(getPdfPageCount(path))
                } catch (e: Exception) {
                    result.error(
                        "pdf_page_count_failed",
                        e.message ?: "Failed to get pdf page count",
                        null,
                    )
                }
            }

            "renderPdfPageToImage" -> {
                val pdfPath = call.argument<String>("pdfPath")
                val pageIndex = call.argument<Int>("pageIndex")
                val outputPath = call.argument<String>("outputPath")
                val width = call.argument<Int>("width")
                if (pdfPath.isNullOrEmpty() || outputPath.isNullOrEmpty() || pageIndex == null) {
                    result.error("invalid_args", "Pdf render arguments are invalid", null)
                    return
                }
                try {
                    result.success(
                        renderPdfPageToImage(
                            pdfPath = pdfPath,
                            pageIndex = pageIndex,
                            outputPath = outputPath,
                            targetWidth = width,
                        ),
                    )
                } catch (e: Exception) {
                    result.error(
                        "pdf_render_failed",
                        e.message ?: "Failed to render pdf page",
                        null,
                    )
                }
            }

            "renderPdfPageToImageBytes" -> {
                val pdfPath = call.argument<String>("pdfPath")
                val pageIndex = call.argument<Int>("pageIndex")
                val width = call.argument<Int>("width")
                if (pdfPath.isNullOrEmpty() || pageIndex == null) {
                    result.error("invalid_args", "Pdf render arguments are invalid", null)
                    return
                }
                try {
                    result.success(
                        renderPdfPageToImageBytes(
                            pdfPath = pdfPath,
                            pageIndex = pageIndex,
                            targetWidth = width,
                        ),
                    )
                } catch (e: Exception) {
                    result.error(
                        "pdf_render_failed",
                        e.message ?: "Failed to render pdf page",
                        null,
                    )
                }
            }

            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    private fun convertHtmlToPdf(html: String, outputPath: String, result: Result) {
        val currentActivity = activity
        if (currentActivity == null || currentActivity.isFinishing) {
            Log.e(TAG, "convertHtmlToPdf aborted: activity unavailable, outputPath=$outputPath")
            result.error(
                "convert_pdf_failed",
                "Current activity is unavailable for html to pdf conversion",
                null,
            )
            return
        }
        val outputFile = File(outputPath)
        outputFile.parentFile?.mkdirs()
        Log.d(
            TAG,
            "convertHtmlToPdf start, outputPath=$outputPath, htmlLength=${html.length}",
        )
        Handler(Looper.getMainLooper()).post {
            var handled = false
            val rootView =
                currentActivity.window?.decorView?.findViewById<ViewGroup>(android.R.id.content)
            if (rootView == null) {
                Log.e(TAG, "convertHtmlToPdf aborted: rootView unavailable, outputPath=$outputPath")
                result.error(
                    "convert_pdf_failed",
                    "Current activity root view is unavailable",
                    null,
                )
                return@post
            }
            val hostLayout = FrameLayout(currentActivity)
            hostLayout.alpha = 0.01f
            hostLayout.isClickable = false
            hostLayout.isFocusable = false
            hostLayout.layoutParams =
                FrameLayout.LayoutParams(
                    PDF_PAGE_WIDTH,
                    FrameLayout.LayoutParams.WRAP_CONTENT,
                )
            val webView = WebView(currentActivity)
            webView.setBackgroundColor(Color.WHITE)
            webView.settings.javaScriptEnabled = true
            webView.settings.domStorageEnabled = true
            webView.settings.loadsImagesAutomatically = true
            webView.settings.useWideViewPort = true
            webView.settings.loadWithOverviewMode = true
            webView.isVerticalScrollBarEnabled = false
            webView.isHorizontalScrollBarEnabled = false
            webView.isScrollbarFadingEnabled = true
            webView.overScrollMode = View.OVER_SCROLL_NEVER
            webView.layoutParams =
                FrameLayout.LayoutParams(
                    PDF_PAGE_WIDTH,
                    FrameLayout.LayoutParams.WRAP_CONTENT,
                )
            hostLayout.addView(webView)
            rootView.addView(hostLayout)
            webView.webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView?, url: String?) {
                    if (handled) {
                        return
                    }
                    Log.d(TAG, "convertHtmlToPdf onPageFinished, outputPath=$outputPath")
                    webView.evaluateJavascript(
                        """
                        (function() {
                          var body = document.body;
                          var html = document.documentElement;
                          return Math.max(
                            body ? body.scrollHeight : 0,
                            body ? body.offsetHeight : 0,
                            html ? html.clientHeight : 0,
                            html ? html.scrollHeight : 0,
                            html ? html.offsetHeight : 0
                          );
                        })();
                        """.trimIndent(),
                    ) { heightValue ->
                        Handler(Looper.getMainLooper()).postDelayed(
                            {
                                if (handled) {
                                    return@postDelayed
                                }
                                try {
                                    val documentHeight = parseJavascriptHeight(heightValue)
                                    Log.d(
                                        TAG,
                                        "renderWebViewToPdf start, outputPath=$outputPath, documentHeight=$documentHeight",
                                    )
                                    renderWebViewToPdf(webView, outputFile, documentHeight)
                                    handled = true
                                    cleanupWebView(rootView, hostLayout, webView)
                                    Log.d(TAG, "convertHtmlToPdf success, outputPath=$outputPath")
                                    result.success(outputFile.absolutePath)
                                } catch (e: Exception) {
                                    handled = true
                                    cleanupWebView(rootView, hostLayout, webView)
                                    Log.e(
                                        TAG,
                                        "convertHtmlToPdf failed, outputPath=$outputPath, message=${e.message}",
                                        e,
                                    )
                                    result.error(
                                        "convert_pdf_failed",
                                        e.message ?: "Failed to render pdf document",
                                        null,
                                    )
                                }
                            },
                            120L,
                        )
                    }
                }
            }
            webView.loadDataWithBaseURL(
                "about:blank",
                normalizeHtmlDocument(html),
                "text/html",
                "utf-8",
                null,
            )
        }
    }

    private fun cleanupWebView(rootView: ViewGroup, hostLayout: FrameLayout, webView: WebView) {
        try {
            hostLayout.removeView(webView)
            rootView.removeView(hostLayout)
        } catch (_: Exception) {
        }
        try {
            webView.stopLoading()
        } catch (_: Exception) {
        }
        try {
            webView.destroy()
        } catch (_: Exception) {
        }
    }

    private fun parseJavascriptHeight(heightValue: String?): Int {
        val cleaned = heightValue?.trim()?.removePrefix("\"")?.removeSuffix("\"") ?: ""
        return cleaned.toFloatOrNull()?.toInt() ?: 0
    }

    private fun renderWebViewToPdf(
        webView: WebView,
        outputFile: File,
        documentHeight: Int,
    ) {
        val pageWidth = PDF_PAGE_WIDTH
        val pageHeight = PDF_PAGE_HEIGHT
        val widthSpec = View.MeasureSpec.makeMeasureSpec(pageWidth, View.MeasureSpec.EXACTLY)
        val heightSpec =
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED)
        webView.measure(widthSpec, heightSpec)
        val scaledContentHeight = (webView.contentHeight * webView.scale).toInt()
        val measuredHeight = webView.measuredHeight
        val totalHeight =
            maxOf(measuredHeight, scaledContentHeight, documentHeight, pageHeight)
        webView.layout(0, 0, pageWidth, totalHeight)
        webView.scrollTo(0, 0)

        val pdfDocument = PdfDocument()
        try {
            var currentTop = 0
            var pageNumber = 1
            while (currentTop < totalHeight) {
                val pageInfo =
                    PdfDocument.PageInfo.Builder(pageWidth, pageHeight, pageNumber).create()
                val page = pdfDocument.startPage(pageInfo)
                val canvas = page.canvas
                canvas.drawColor(Color.WHITE)
                canvas.save()
                canvas.translate(0f, -currentTop.toFloat())
                webView.draw(canvas)
                canvas.restore()
                pdfDocument.finishPage(page)
                currentTop += pageHeight
                pageNumber++
            }
            FileOutputStream(outputFile).use { stream ->
                pdfDocument.writeTo(stream)
                stream.flush()
            }
            Log.d(
                TAG,
                "renderWebViewToPdf end, outputPath=${outputFile.absolutePath}, measuredHeight=$measuredHeight, scaledContentHeight=$scaledContentHeight, documentHeight=$documentHeight, totalHeight=$totalHeight, pageCount=${pageNumber - 1}",
            )
        } finally {
            pdfDocument.close()
        }
    }

    private fun scanFile(path: String, result: Result) {
        val file = File(path)
        if (!file.exists()) {
            result.success(false)
            return
        }
        MediaScannerConnection.scanFile(
            binding.applicationContext,
            arrayOf(file.absolutePath),
            arrayOf(queryMimeType(file)),
        ) { _, _ ->
            result.success(true)
        }
    }

    private fun queryMimeType(file: File): String? {
        val extension = file.extension.lowercase()
        if (extension.isEmpty()) {
            return null
        }
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: when (extension) {
                "pdf" -> "application/pdf"
                else -> null
            }
    }

    private fun getPdfPageCount(path: String): Int {
        val file = File(path)
        if (!file.exists()) {
            throw IllegalArgumentException("The file does not exist.")
        }
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            PdfRenderer(descriptor).use { renderer ->
                return renderer.pageCount
            }
        }
    }

    private fun renderPdfPageToImage(
        pdfPath: String,
        pageIndex: Int,
        outputPath: String,
        targetWidth: Int?,
    ): String {
        val file = File(pdfPath)
        if (!file.exists()) {
            throw IllegalArgumentException("The file does not exist.")
        }
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            PdfRenderer(descriptor).use { renderer ->
                if (pageIndex < 0 || pageIndex >= renderer.pageCount) {
                    throw IllegalArgumentException("Page index is out of range.")
                }
                renderer.openPage(pageIndex).use { page ->
                    val safeWidth = targetWidth?.takeIf { it > 0 } ?: (page.width * 2)
                    val scale = safeWidth.toFloat() / page.width.toFloat()
                    val safeHeight = (page.height * scale).toInt().coerceAtLeast(1)
                    val bitmap = Bitmap.createBitmap(
                        safeWidth.coerceAtLeast(1),
                        safeHeight,
                        Bitmap.Config.ARGB_8888,
                    )
                    val canvas = Canvas(bitmap)
                    canvas.drawColor(Color.WHITE)
                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    val outputFile = File(outputPath)
                    outputFile.parentFile?.mkdirs()
                    FileOutputStream(outputFile).use { stream ->
                        bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
                        stream.flush()
                    }
                    bitmap.recycle()
                    return outputFile.absolutePath
                }
            }
        }
    }

    private fun renderPdfPageToImageBytes(
        pdfPath: String,
        pageIndex: Int,
        targetWidth: Int?,
    ): ByteArray {
        val file = File(pdfPath)
        if (!file.exists()) {
            throw IllegalArgumentException("The file does not exist.")
        }
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            PdfRenderer(descriptor).use { renderer ->
                if (pageIndex < 0 || pageIndex >= renderer.pageCount) {
                    throw IllegalArgumentException("Page index is out of range.")
                }
                renderer.openPage(pageIndex).use { page ->
                    val safeWidth = targetWidth?.takeIf { it > 0 } ?: (page.width * 2)
                    val scale = safeWidth.toFloat() / page.width.toFloat()
                    val safeHeight = (page.height * scale).toInt().coerceAtLeast(1)
                    val bitmap = Bitmap.createBitmap(
                        safeWidth.coerceAtLeast(1),
                        safeHeight,
                        Bitmap.Config.ARGB_8888,
                    )
                    val canvas = Canvas(bitmap)
                    canvas.drawColor(Color.WHITE)
                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    val stream = ByteArrayOutputStream()
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
                    bitmap.recycle()
                    return stream.toByteArray()
                }
            }
        }
    }

    private fun loadDocContent(path: String): Map<String, String> {
        val file = File(path)
        val fileBytes = file.readBytes()
        if (fileBytes.size < 4) {
            throw IllegalArgumentException("The file is too small to identify.")
        }
        val header = ByteArray(8)
        FileInputStream(file).use { inputStream ->
            val count = inputStream.read(header)
            if (count < 4) {
                throw IllegalArgumentException("The file is too small to identify.")
            }
        }

        if (isOoxmlFile(header)) {
            throw IllegalArgumentException("The document is really an OOXML file.")
        }

        if (isRtfFile(file)) {
            val text = decodeTextContent(fileBytes)
            return mapOf(
                "html" to wrapPreformattedHtml(text),
                "text" to text,
                "type" to "rtf",
            )
        }

        if (isHtmlFile(fileBytes)) {
            val text = decodeTextContent(fileBytes)
            return mapOf(
                "html" to text,
                "text" to stripHtmlTags(text),
                "type" to "html",
            )
        }

        if (isXmlFile(fileBytes)) {
            val text = decodeTextContent(fileBytes)
            return mapOf(
                "html" to wrapPreformattedHtml(text),
                "text" to text,
                "type" to "xml",
            )
        }

        if (isPlainTextFile(fileBytes)) {
            val text = decodeTextContent(fileBytes)
            return mapOf(
                "html" to wrapPreformattedHtml(text),
                "text" to text,
                "type" to "text",
            )
        }

        if (!isOle2File(header)) {
            throw IllegalArgumentException(
                "The file is not a standard Word .doc document. Detected type: ${describeFileType(fileBytes)}.",
            )
        }

        val html = convertOle2DocToHtml(file)
        val text = extractOle2DocText(file)
        return mapOf(
            "html" to html,
            "text" to text,
            "type" to "ole2",
        )
    }

    private fun convertDocToHtml(path: String): String {
        val file = File(path)
        val fileBytes = file.readBytes()
        if (fileBytes.size < 4) {
            throw IllegalArgumentException("The file is too small to identify.")
        }
        val header = ByteArray(8)
        FileInputStream(file).use { inputStream ->
            val count = inputStream.read(header)
            if (count < 4) {
                throw IllegalArgumentException("The file is too small to identify.")
            }
        }

        if (isOoxmlFile(header)) {
            throw IllegalArgumentException("The document is really an OOXML file.")
        }

        if (isRtfFile(file)) {
            return convertRtfToHtml(file)
        }

        if (isHtmlFile(fileBytes)) {
            return decodeTextContent(fileBytes)
        }

        if (isXmlFile(fileBytes)) {
            return wrapPreformattedHtml(decodeTextContent(fileBytes))
        }

        if (isPlainTextFile(fileBytes)) {
            return wrapPreformattedHtml(decodeTextContent(fileBytes))
        }

        if (!isOle2File(header)) {
            throw IllegalArgumentException(
                "The file is not a standard Word .doc document. Detected type: ${describeFileType(fileBytes)}.",
            )
        }

        return convertOle2DocToHtml(file)
    }

    private fun convertOle2DocToHtml(file: File): String {
        FileInputStream(file).use { inputStream ->
            val wordDoc = HWPFDocument(inputStream)
            val converter = WordToHtmlConverter(
                DocumentBuilderFactory.newInstance()
                    .newDocumentBuilder()
                    .newDocument(),
            )
            converter.processDocument(wordDoc)
            val writer = StringWriter()
            val transformer = TransformerFactory.newInstance().newTransformer()
            transformer.setOutputProperty(OutputKeys.ENCODING, "utf-8")
            transformer.setOutputProperty(OutputKeys.METHOD, "html")
            transformer.setOutputProperty(OutputKeys.INDENT, "yes")
            transformer.transform(
                DOMSource(converter.document),
                StreamResult(writer),
            )
            return writer.toString()
        }
    }

    private fun extractOle2DocText(file: File): String {
        FileInputStream(file).use { inputStream ->
            val wordDoc = HWPFDocument(inputStream)
            return normalizeLoadedText(wordDoc.range.text())
        }
    }

    private fun saveDocTextContent(path: String, text: String) {
        val file = File(path)
        val fileBytes = file.readBytes()
        val header = ByteArray(8)
        FileInputStream(file).use { inputStream ->
            inputStream.read(header)
        }

        when {
            isOle2File(header) -> saveOle2DocTextContent(file, text)
            isHtmlFile(fileBytes) -> file.writeText(buildHtmlDocument(text), StandardCharsets.UTF_8)
            else -> file.writeText(text, StandardCharsets.UTF_8)
        }
    }

    private fun saveOle2DocTextContent(file: File, text: String) {
        FileInputStream(file).use { inputStream ->
            val wordDoc = HWPFDocument(inputStream)
            val range = wordDoc.range
            range.replaceText(range.text(), normalizeSavedText(text))
            wordDoc.write(file)
        }
    }

    private fun isOoxmlFile(header: ByteArray): Boolean {
        return header.size >= 4 &&
            header[0] == 0x50.toByte() &&
            header[1] == 0x4B.toByte() &&
            header[2] == 0x03.toByte() &&
            header[3] == 0x04.toByte()
    }

    private fun isOle2File(header: ByteArray): Boolean {
        val ole2Header = byteArrayOf(
            0xD0.toByte(),
            0xCF.toByte(),
            0x11.toByte(),
            0xE0.toByte(),
            0xA1.toByte(),
            0xB1.toByte(),
            0x1A.toByte(),
            0xE1.toByte(),
        )
        if (header.size < ole2Header.size) {
            return false
        }
        for (index in ole2Header.indices) {
            if (header[index] != ole2Header[index]) {
                return false
            }
        }
        return true
    }

    private fun isRtfFile(file: File): Boolean {
        FileInputStream(file).use { inputStream ->
            val header = ByteArray(5)
            val count = inputStream.read(header)
            if (count < 5) {
                return false
            }
            val value = String(header, Charset.forName("UTF-8"))
            return value == "{\\rtf"
        }
    }

    private fun convertRtfToHtml(file: File): String {
        return wrapPreformattedHtml(file.readText(Charset.forName("UTF-8")))
    }

    private fun isHtmlFile(bytes: ByteArray): Boolean {
        val content = decodeTextContent(bytes).trimStart().lowercase()
        return content.startsWith("<!doctype html") ||
            content.startsWith("<html") ||
            content.contains("<body")
    }

    private fun isXmlFile(bytes: ByteArray): Boolean {
        val content = decodeTextContent(bytes).trimStart().lowercase()
        return content.startsWith("<?xml") ||
            content.startsWith("<w:worddocument") ||
            content.startsWith("<office:document-content")
    }

    private fun isPlainTextFile(bytes: ByteArray): Boolean {
        if (bytes.isEmpty()) {
            return false
        }
        val sampleSize = minOf(bytes.size, 4096)
        var printableCount = 0
        for (index in 0 until sampleSize) {
            val value = bytes[index].toInt() and 0xFF
            if (value == 0) {
                return false
            }
            if (value == 9 || value == 10 || value == 13 || value in 32..126 || value >= 160) {
                printableCount++
            }
        }
        return printableCount.toDouble() / sampleSize >= 0.85
    }

    private fun decodeTextContent(bytes: ByteArray): String {
        val utf8Text = String(bytes, StandardCharsets.UTF_8)
        val replacementCount = utf8Text.count { it == '\uFFFD' }
        if (replacementCount > utf8Text.length / 10) {
            return String(bytes, Charset.forName("GBK"))
        }
        return utf8Text
    }

    private fun wrapPreformattedHtml(content: String): String {
        val escaped = content
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("\n", "<br/>")
        return "<html><body><pre>$escaped</pre></body></html>"
    }

    private fun buildHtmlDocument(content: String): String {
        return "<html><body><pre>${escapeHtml(content)}</pre></body></html>"
    }

    private fun normalizeHtmlDocument(content: String): String {
        val trimmed = content.trim()
        val lower = trimmed.lowercase()
        if (lower.startsWith("<html") || lower.startsWith("<!doctype html")) {
            return trimmed
        }
        return "<html><body>$trimmed</body></html>"
    }

    private fun escapeHtml(content: String): String {
        return content
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("\n", "<br/>")
    }

    private fun stripHtmlTags(content: String): String {
        return content
            .replace(Regex("(?i)<br\\s*/?>"), "\n")
            .replace(Regex("(?i)</p>"), "\n")
            .replace(Regex("<[^>]+>"), "")
            .replace("&nbsp;", " ")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&amp;", "&")
            .trim()
    }

    private fun normalizeLoadedText(content: String): String {
        return content
            .replace("\u0007", "\n")
            .replace("\r", "\n")
            .replace(Regex("\n{3,}"), "\n\n")
            .trim()
    }

    private fun normalizeSavedText(content: String): String {
        val normalized = content
            .replace("\r\n", "\r")
            .replace("\n", "\r")
            .trimEnd()
        return if (normalized.isEmpty()) "\r" else "$normalized\r"
    }

    private fun describeFileType(bytes: ByteArray): String {
        return when {
            isOoxmlFile(bytes) -> "OOXML/ZIP"
            isRtfFileContent(bytes) -> "RTF"
            isHtmlFile(bytes) -> "HTML"
            isXmlFile(bytes) -> "XML"
            isPlainTextFile(bytes) -> "plain text"
            else -> "unknown binary"
        }
    }

    private fun isRtfFileContent(bytes: ByteArray): Boolean {
        if (bytes.size < 5) {
            return false
        }
        val prefix = String(bytes.copyOfRange(0, 5), StandardCharsets.UTF_8)
        return prefix == "{\\rtf"
    }
}
