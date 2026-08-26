package com.flutter.preview.file.flutter_preview_file

import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.Process
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File
import java.util.UUID

internal class PdfImageWorkerClient(private val context: Context) {
    private data class Request(
        val taskId: String,
        val imagePaths: ArrayList<String>,
        val outputPath: String,
        val maxSidePx: Int,
        val result: Result,
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private val callbackMessenger = Messenger(CallbackHandler())
    private var serviceMessenger: Messenger? = null
    private var connection: ServiceConnection? = null
    private var activeRequest: Request? = null
    private var pendingRequest: Request? = null
    private var restartGeneration = 0

    fun generate(
        imagePaths: List<String>,
        outputPath: String,
        maxSidePx: Int,
        result: Result,
    ) {
        val request =
            Request(
                taskId = UUID.randomUUID().toString(),
                imagePaths = ArrayList(imagePaths),
                outputPath = outputPath,
                maxSidePx = maxSidePx,
                result = result,
            )

        pendingRequest?.result?.error(
            "generate_pdf_replaced",
            "PDF generation was replaced by a newer task",
            null,
        )
        pendingRequest = request

        if (activeRequest != null) {
            val replacedRequest = activeRequest
            replacedRequest?.result?.error(
                "generate_pdf_replaced",
                "PDF generation was replaced by a newer task",
                null,
            )
            activeRequest = null
            replacedRequest?.let(::scheduleTemporaryFileCleanup)
            restartWorker()
            return
        }

        val messenger = serviceMessenger
        if (messenger != null) {
            sendPendingRequest(messenger)
        } else if (connection == null) {
            bindWorker()
        }
    }

    fun detach() {
        pendingRequest?.result?.error("generate_pdf_detached", "Flutter engine detached", null)
        activeRequest?.result?.error("generate_pdf_detached", "Flutter engine detached", null)
        pendingRequest = null
        activeRequest = null
        restartGeneration++
        unbindWorker()
    }

    private fun restartWorker() {
        val generation = ++restartGeneration
        runCatching {
            serviceMessenger?.send(
                Message.obtain(null, PdfImageWorkerProtocol.MSG_TERMINATE),
            )
        }
        serviceMessenger = null
        unbindWorker()
        killWorkerProcessIfRunning()
        mainHandler.postDelayed(
            {
                if (generation == restartGeneration && pendingRequest != null) {
                    bindWorker()
                }
            },
            WORKER_RESTART_DELAY_MS,
        )
    }

    private fun bindWorker() {
        if (connection != null || pendingRequest == null) return
        val newConnection =
            object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                    if (connection !== this) return
                    val messenger = Messenger(binder)
                    serviceMessenger = messenger
                    sendPendingRequest(messenger)
                }

                override fun onServiceDisconnected(name: ComponentName) {
                    if (connection !== this) return
                    serviceMessenger = null
                    connection = null
                    val failedRequest = activeRequest
                    activeRequest = null
                    failedRequest?.let(::scheduleTemporaryFileCleanup)
                    failedRequest?.result?.error(
                        "generate_pdf_worker_died",
                        "PDF worker process stopped unexpectedly",
                        null,
                    )
                    if (pendingRequest != null) bindWorker()
                }
            }
        connection = newConnection
        val bound =
            context.bindService(
                Intent(context, PdfImageWorkerService::class.java),
                newConnection,
                Context.BIND_AUTO_CREATE,
            )
        if (!bound) {
            connection = null
            val request = pendingRequest
            pendingRequest = null
            request?.result?.error(
                "generate_pdf_worker_unavailable",
                "Failed to start PDF worker process",
                null,
            )
        }
    }

    private fun sendPendingRequest(messenger: Messenger) {
        val request = pendingRequest ?: return
        pendingRequest = null
        activeRequest = request
        val message = Message.obtain(null, PdfImageWorkerProtocol.MSG_GENERATE)
        message.replyTo = callbackMessenger
        message.data = Bundle().apply {
            putString(PdfImageWorkerProtocol.KEY_TASK_ID, request.taskId)
            putStringArrayList(PdfImageWorkerProtocol.KEY_IMAGE_PATHS, request.imagePaths)
            putString(PdfImageWorkerProtocol.KEY_OUTPUT_PATH, request.outputPath)
            putInt(PdfImageWorkerProtocol.KEY_MAX_SIDE_PX, request.maxSidePx)
        }
        try {
            messenger.send(message)
        } catch (exception: Exception) {
            activeRequest = null
            request.result.error(
                "generate_pdf_worker_unavailable",
                exception.message ?: "Failed to communicate with PDF worker process",
                null,
            )
            restartWorker()
        }
    }

    private fun unbindWorker() {
        val oldConnection = connection ?: return
        connection = null
        serviceMessenger = null
        runCatching { context.unbindService(oldConnection) }
    }

    private fun killWorkerProcessIfRunning() {
        val processName = "${context.packageName}:pdf_worker"
        val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        activityManager.runningAppProcesses
            ?.firstOrNull { it.processName == processName && it.uid == Process.myUid() }
            ?.let { Process.killProcess(it.pid) }
    }

    private fun scheduleTemporaryFileCleanup(request: Request) {
        mainHandler.postDelayed(
            {
                File("${request.outputPath}.generating-${request.taskId}").delete()
            },
            TEMPORARY_FILE_CLEANUP_DELAY_MS,
        )
    }

    private inner class CallbackHandler : Handler(Looper.getMainLooper()) {
        override fun handleMessage(message: Message) {
            if (
                message.what != PdfImageWorkerProtocol.MSG_SUCCESS &&
                    message.what != PdfImageWorkerProtocol.MSG_ERROR
            ) {
                super.handleMessage(message)
                return
            }
            val taskId = message.data.getString(PdfImageWorkerProtocol.KEY_TASK_ID)
            val request = activeRequest
            if (request == null || request.taskId != taskId) return
            activeRequest = null
            if (message.what == PdfImageWorkerProtocol.MSG_SUCCESS) {
                request.result.success(
                    message.data.getString(PdfImageWorkerProtocol.KEY_OUTPUT_PATH),
                )
            } else {
                request.result.error(
                    "generate_pdf_failed",
                    message.data.getString(PdfImageWorkerProtocol.KEY_ERROR_MESSAGE)
                        ?: "Failed to generate PDF",
                    null,
                )
            }
        }
    }

    private companion object {
        const val WORKER_RESTART_DELAY_MS = 250L
        const val TEMPORARY_FILE_CLEANUP_DELAY_MS = 500L
    }
}
