package com.mediapicker

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableArray
import com.facebook.react.bridge.WritableMap
import java.io.File

/** A file on its way back to JS, with what will be reported about it. */
internal data class Processed(
  val file: File,
  val mime: String,
  val displayName: String,
  /** Why this file is still over its budget, when it is. */
  val compressionSkipped: String? = null
)

/** Every `errorCode` the module reports; mirrors `ErrorCode` in src/types.ts. */
internal object ErrorCode {
  const val PERMISSION = "permission"
  const val CANNOT_PROCESS_ASSET = "cannot_process_asset"
  const val CROP_FAILED = "crop_failed"
  const val COMPRESS_FAILED = "compress_failed"
  const val CAMERA_UNAVAILABLE = "camera_unavailable"
  const val INVALID_OPTIONS = "invalid_options"
  const val PICKER_BUSY = "picker_busy"
  const val OTHERS = "others"
}

internal object Results {

  fun asset(
    processed: Processed,
    originalUri: String?,
    options: ReadableMap,
    cropRect: WritableMap?
  ): WritableMap {
    val map = Arguments.createMap()
    val file = processed.file

    map.putString("uri", "file://${file.absolutePath}")
    map.putString("fileName", processed.displayName)
    map.putDouble("fileSize", file.length().toDouble())
    map.putString("type", processed.mime)

    if (MediaFiles.isVideo(processed.mime)) {
      val meta = VideoProcessing.videoMeta(file)
      map.putInt("width", meta.width)
      map.putInt("height", meta.height)
      map.putDouble("duration", meta.durationMs.toDouble())
      map.putDouble("bitrate", meta.bitrate.toDouble())
    } else {
      val (w, h) = ImageProcessing.imageDimensions(file)
      map.putInt("width", w)
      map.putInt("height", h)
      if (options.flag("includeExif")) {
        map.putMap("exif", ImageProcessing.exifMap(file))
      }
      if (options.flag("includeBase64")) {
        map.putString("base64", MediaFiles.base64(file))
      }
    }

    if (options.flag("includeExtra")) {
      map.putString("id", processed.displayName)
      map.putString("timestamp", file.lastModified().toString())
    }
    originalUri?.let { map.putString("originalPath", it) }
    cropRect?.let { map.putMap("cropRect", it) }
    processed.compressionSkipped?.let { map.putString("compressionSkipped", it) }
    return map
  }

  fun success(
    assets: WritableArray,
    deselected: List<String> = emptyList()
  ): WritableMap = Arguments.createMap().apply {
    putBoolean("didCancel", false)
    putArray("assets", assets)
    putArray("deselected", Arguments.fromList(deselected))
  }

  fun cancelled(): WritableMap = Arguments.createMap().apply {
    putBoolean("didCancel", true)
    putArray("assets", Arguments.createArray())
  }

  fun error(code: String, message: String): WritableMap = Arguments.createMap().apply {
    putBoolean("didCancel", false)
    putString("errorCode", code)
    putString("errorMessage", message)
    putArray("assets", Arguments.createArray())
  }
}

// --- option readers -------------------------------------------------------

internal fun ReadableMap.intOr(key: String, fallback: Int) =
  if (hasKey(key) && !isNull(key)) getInt(key) else fallback

internal fun ReadableMap.longOr(key: String, fallback: Long = 0L) =
  if (hasKey(key) && !isNull(key)) getDouble(key).toLong() else fallback

internal fun ReadableMap.doubleOr(key: String, fallback: Double) =
  if (hasKey(key) && !isNull(key)) getDouble(key) else fallback

internal fun ReadableMap.flag(key: String, fallback: Boolean = false) =
  if (hasKey(key)) getBoolean(key) else fallback

internal fun ReadableMap.stringList(key: String): List<String> {
  if (!hasKey(key) || isNull(key)) return emptyList()
  val array = getArray(key) ?: return emptyList()
  return (0 until array.size()).mapNotNull { array.getString(it) }
}
