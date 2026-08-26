package com.flutter.preview.file.flutter_preview_file

import android.app.Service
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.Process
import androidx.exifinterface.media.ExifInterface
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.graphics.image.LosslessFactory
import java.io.File
import java.io.FileInputStream
import kotlin.math.max
import kotlin.math.min

class PdfImageWorkerService : Service() {
    private val incomingMessenger = Messenger(IncomingHandler())

    override fun onBind(intent: Intent?): IBinder = incomingMessenger.binder

    private inner class IncomingHandler : Handler(Looper.getMainLooper()) {
        override fun handleMessage(message: Message) {
            when (message.what) {
                PdfImageWorkerProtocol.MSG_GENERATE -> startGeneration(message)
                PdfImageWorkerProtocol.MSG_TERMINATE -> Process.killProcess(Process.myPid())
                else -> super.handleMessage(message)
            }
        }
    }

    private fun startGeneration(message: Message) {
        val replyTo = message.replyTo ?: return
        val data = message.data
        val taskId = data.getString(PdfImageWorkerProtocol.KEY_TASK_ID).orEmpty()
        val imagePaths =
            data.getStringArrayList(PdfImageWorkerProtocol.KEY_IMAGE_PATHS).orEmpty()
        val outputPath = data.getString(PdfImageWorkerProtocol.KEY_OUTPUT_PATH).orEmpty()
        val maxSidePx = data.getInt(PdfImageWorkerProtocol.KEY_MAX_SIDE_PX, 2000)

        Thread(
            {
                try {
                    val resultPath =
                        generatePdfFromImages(imagePaths, outputPath, maxSidePx, taskId)
                    sendResult(
                        replyTo = replyTo,
                        what = PdfImageWorkerProtocol.MSG_SUCCESS,
                        taskId = taskId,
                        outputPath = resultPath,
                    )
                } catch (throwable: Throwable) {
                    File(temporaryPath(outputPath, taskId)).delete()
                    sendResult(
                        replyTo = replyTo,
                        what = PdfImageWorkerProtocol.MSG_ERROR,
                        taskId = taskId,
                        errorMessage = throwable.message ?: "Failed to generate PDF",
                    )
                }
            },
            "flutter-preview-pdf-$taskId",
        ).start()
    }

    private fun sendResult(
        replyTo: Messenger,
        what: Int,
        taskId: String,
        outputPath: String? = null,
        errorMessage: String? = null,
    ) {
        val response = Message.obtain(null, what)
        response.data = android.os.Bundle().apply {
            putString(PdfImageWorkerProtocol.KEY_TASK_ID, taskId)
            outputPath?.let { putString(PdfImageWorkerProtocol.KEY_OUTPUT_PATH, it) }
            errorMessage?.let { putString(PdfImageWorkerProtocol.KEY_ERROR_MESSAGE, it) }
        }
        runCatching { replyTo.send(response) }
    }

    private fun generatePdfFromImages(
        imagePaths: List<String>,
        outputPath: String,
        maxSidePx: Int,
        taskId: String,
    ): String {
        require(imagePaths.isNotEmpty()) { "Please select at least one image" }
        require(outputPath.isNotEmpty()) { "Output path is invalid" }

        PDFBoxResourceLoader.init(applicationContext)
        val outputFile = File(outputPath)
        outputFile.parentFile?.mkdirs()
        val temporaryFile = File(temporaryPath(outputPath, taskId))
        temporaryFile.delete()

        try {
            PDDocument().use { document ->
                var addedPages = 0
                for (path in imagePaths) {
                    val imageFile = File(path)
                    check(imageFile.exists()) {
                        "The image does not exist. Please select another image"
                    }
                    val bitmap = decodeBitmapForPdf(imageFile, maxSidePx) ?: continue
                    val rotated = rotateBitmap(bitmap, readExifRotationDegrees(imageFile))
                    if (rotated !== bitmap) bitmap.recycle()

                    try {
                        val pageRect =
                            if (rotated.width >= rotated.height) {
                                PDRectangle(PDRectangle.A4.height, PDRectangle.A4.width)
                            } else {
                                PDRectangle.A4
                            }
                        val page = PDPage(pageRect)
                        document.addPage(page)
                        addedPages++
                        val image = LosslessFactory.createFromImage(document, rotated)
                        val scale =
                            min(
                                page.mediaBox.width / rotated.width.toFloat(),
                                page.mediaBox.height / rotated.height.toFloat(),
                            )
                        val drawWidth = rotated.width * scale
                        val drawHeight = rotated.height * scale
                        PDPageContentStream(
                            document,
                            page,
                            PDPageContentStream.AppendMode.OVERWRITE,
                            true,
                        ).use { stream ->
                            stream.drawImage(
                                image,
                                (page.mediaBox.width - drawWidth) / 2f,
                                (page.mediaBox.height - drawHeight) / 2f,
                                drawWidth,
                                drawHeight,
                            )
                        }
                    } finally {
                        rotated.recycle()
                    }
                }
                check(addedPages > 0) { "No pages added" }
                document.save(temporaryFile)
            }

            if (outputFile.exists() && !outputFile.delete()) {
                error("Failed to replace output PDF")
            }
            if (!temporaryFile.renameTo(outputFile)) {
                temporaryFile.copyTo(outputFile, overwrite = true)
                temporaryFile.delete()
            }
            return outputFile.absolutePath
        } catch (throwable: Throwable) {
            temporaryFile.delete()
            throw throwable
        }
    }

    private fun decodeBitmapForPdf(imageFile: File, maxSidePx: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        FileInputStream(imageFile).use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        val safeMaxSide = maxSidePx.coerceAtLeast(1)
        var sampleSize = 1
        while (max(bounds.outWidth / sampleSize, bounds.outHeight / sampleSize) > safeMaxSide) {
            sampleSize *= 2
        }
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        return FileInputStream(imageFile).use { BitmapFactory.decodeStream(it, null, options) }
    }

    private fun readExifRotationDegrees(imageFile: File): Int =
        try {
            when (
                ExifInterface(imageFile.absolutePath).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL,
                )
            ) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90
                ExifInterface.ORIENTATION_ROTATE_180 -> 180
                ExifInterface.ORIENTATION_ROTATE_270 -> 270
                else -> 0
            }
        } catch (_: Exception) {
            0
        }

    private fun rotateBitmap(bitmap: Bitmap, degrees: Int): Bitmap {
        if (degrees % 360 == 0) return bitmap
        val matrix = Matrix().apply { postRotate(degrees.toFloat()) }
        return Bitmap.createBitmap(
            bitmap,
            0,
            0,
            bitmap.width,
            bitmap.height,
            matrix,
            true,
        )
    }

    private fun temporaryPath(outputPath: String, taskId: String): String =
        "$outputPath.generating-$taskId"
}
