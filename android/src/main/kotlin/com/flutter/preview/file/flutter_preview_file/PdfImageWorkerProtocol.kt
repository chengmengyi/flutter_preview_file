package com.flutter.preview.file.flutter_preview_file

internal object PdfImageWorkerProtocol {
    const val MSG_GENERATE = 1
    const val MSG_TERMINATE = 2
    const val MSG_SUCCESS = 3
    const val MSG_ERROR = 4

    const val KEY_TASK_ID = "taskId"
    const val KEY_IMAGE_PATHS = "imagePaths"
    const val KEY_OUTPUT_PATH = "outputPath"
    const val KEY_MAX_SIDE_PX = "maxSidePx"
    const val KEY_ERROR_MESSAGE = "errorMessage"
}
