package com.mediapicker

import android.content.Context
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Base64
import androidx.exifinterface.media.ExifInterface
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.WritableMap
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

object MediaUtils {

  private const val CACHE_DIR = "rn_media_picker"

  fun cacheDir(context: Context): File =
    File(context.cacheDir, CACHE_DIR).apply { if (!exists()) mkdirs() }

  fun newCacheFile(context: Context, extension: String): File =
    File(cacheDir(context), "${UUID.randomUUID()}.$extension")

  fun mimeType(context: Context, uri: Uri): String =
    context.contentResolver.getType(uri) ?: "application/octet-stream"

  fun isVideo(mime: String) = mime.startsWith("video/")

  fun displayName(context: Context, uri: Uri, fallback: String): String {
    var cursor: Cursor? = null
    try {
      cursor = context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
      if (cursor != null && cursor.moveToFirst()) {
        val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
        if (index >= 0) {
          val name = cursor.getString(index)
          if (!name.isNullOrBlank()) return name
        }
      }
    } catch (_: Exception) {
    } finally {
      cursor?.close()
    }
    return fallback
  }

  /**
   * The gallery hands back a content:// URI whose permission grant dies with the
   * activity result. Anything downstream (upload, compression, a second crop pass)
   * needs a real file, so every asset is copied into app cache up front.
   */
  fun copyToCache(context: Context, uri: Uri, extension: String): File {
    val target = newCacheFile(context, extension)
    context.contentResolver.openInputStream(uri)?.use { input ->
      FileOutputStream(target).use { output -> input.copyTo(output, 64 * 1024) }
    } ?: throw IllegalStateException("Could not open a stream for $uri")
    return target
  }

  /** Swap a display name's extension for the one the bytes actually have. */
  fun withExtension(name: String, extension: String): String {
    if (extension.isBlank()) return name
    val base = name.substringBeforeLast('.', name)
    return "$base.$extension"
  }

  fun extensionFor(mime: String, forceJpg: Boolean): String = when {
    mime.startsWith("video/") -> mime.substringAfter('/').substringBefore(';').ifBlank { "mp4" }
    forceJpg -> "jpg"
    mime == "image/png" -> "png"
    mime == "image/webp" -> "webp"
    mime == "image/gif" -> "gif"
    else -> "jpg"
  }

  // --- images -------------------------------------------------------------

  /**
   * Resize and/or re-encode in place. Returns the file that should be reported
   * back to JS — the original when no work was required.
   */
  fun processImage(
    context: Context,
    source: File,
    mime: String,
    maxWidth: Int,
    maxHeight: Int,
    quality: Double,
    forceJpg: Boolean
  ): File {
    val needsResize = maxWidth > 0 || maxHeight > 0
    val needsRecode = quality < 1.0 || (forceJpg && mime != "image/jpeg")
    if (!needsResize && !needsRecode) return source
    if (mime == "image/gif") return source // re-encoding would drop the animation

    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(source.absolutePath, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return source

    val targetW = if (maxWidth > 0) maxWidth else bounds.outWidth
    val targetH = if (maxHeight > 0) maxHeight else bounds.outHeight
    val scale = minOf(
      targetW.toDouble() / bounds.outWidth,
      targetH.toDouble() / bounds.outHeight,
      1.0
    )

    val decodeOptions = BitmapFactory.Options().apply {
      inSampleSize = sampleSizeFor(bounds.outWidth, bounds.outHeight, targetW, targetH)
    }
    var bitmap = BitmapFactory.decodeFile(source.absolutePath, decodeOptions) ?: return source
    bitmap = applyExifRotation(source, bitmap)

    if (scale < 1.0) {
      val w = (bounds.outWidth * scale).toInt().coerceAtLeast(1)
      val h = (bounds.outHeight * scale).toInt().coerceAtLeast(1)
      if (w != bitmap.width || h != bitmap.height) {
        val scaled = Bitmap.createScaledBitmap(bitmap, w, h, true)
        if (scaled != bitmap) bitmap.recycle()
        bitmap = scaled
      }
    }

    val usePng = !forceJpg && mime == "image/png"
    val output = newCacheFile(context, if (usePng) "png" else "jpg")
    FileOutputStream(output).use { out ->
      bitmap.compress(
        if (usePng) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG,
        (quality * 100).toInt().coerceIn(1, 100),
        out
      )
    }
    bitmap.recycle()
    if (source.absolutePath != output.absolutePath) source.delete()
    return output
  }

  private fun sampleSizeFor(width: Int, height: Int, reqWidth: Int, reqHeight: Int): Int {
    var sample = 1
    var w = width
    var h = height
    while (w / 2 >= reqWidth && h / 2 >= reqHeight) {
      w /= 2
      h /= 2
      sample *= 2
    }
    return sample
  }

  private fun applyExifRotation(file: File, bitmap: Bitmap): Bitmap {
    val degrees = try {
      when (ExifInterface(file.absolutePath).getAttributeInt(
        ExifInterface.TAG_ORIENTATION,
        ExifInterface.ORIENTATION_NORMAL
      )) {
        ExifInterface.ORIENTATION_ROTATE_90 -> 90f
        ExifInterface.ORIENTATION_ROTATE_180 -> 180f
        ExifInterface.ORIENTATION_ROTATE_270 -> 270f
        else -> 0f
      }
    } catch (_: Exception) {
      0f
    }
    if (degrees == 0f) return bitmap
    val matrix = Matrix().apply { postRotate(degrees) }
    val rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    if (rotated != bitmap) bitmap.recycle()
    return rotated
  }

  fun imageDimensions(file: File): Pair<Int, Int> {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.absolutePath, bounds)
    return bounds.outWidth to bounds.outHeight
  }

  fun exifMap(file: File): WritableMap {
    val map = Arguments.createMap()
    try {
      val exif = ExifInterface(file.absolutePath)
      val tags = listOf(
        ExifInterface.TAG_DATETIME,
        ExifInterface.TAG_MAKE,
        ExifInterface.TAG_MODEL,
        ExifInterface.TAG_ORIENTATION,
        ExifInterface.TAG_F_NUMBER,
        ExifInterface.TAG_EXPOSURE_TIME,
        ExifInterface.TAG_FOCAL_LENGTH,
        ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY,
        ExifInterface.TAG_GPS_LATITUDE,
        ExifInterface.TAG_GPS_LONGITUDE,
        ExifInterface.TAG_IMAGE_WIDTH,
        ExifInterface.TAG_IMAGE_LENGTH
      )
      for (tag in tags) exif.getAttribute(tag)?.let { map.putString(tag, it) }
    } catch (_: Exception) {
    }
    return map
  }

  // --- video --------------------------------------------------------------

  data class VideoMeta(val width: Int, val height: Int, val durationMs: Long, val bitrate: Long)

  fun videoMeta(file: File): VideoMeta {
    val retriever = MediaMetadataRetriever()
    return try {
      retriever.setDataSource(file.absolutePath)
      fun read(key: Int) = retriever.extractMetadata(key)?.toLongOrNull() ?: 0L
      val rotation = read(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION).toInt()
      val rawW = read(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH).toInt()
      val rawH = read(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT).toInt()
      val swap = rotation == 90 || rotation == 270
      VideoMeta(
        width = if (swap) rawH else rawW,
        height = if (swap) rawW else rawH,
        durationMs = read(MediaMetadataRetriever.METADATA_KEY_DURATION),
        bitrate = read(MediaMetadataRetriever.METADATA_KEY_BITRATE)
      )
    } catch (_: Exception) {
      VideoMeta(0, 0, 0, 0)
    } finally {
      try { retriever.release() } catch (_: Exception) {}
    }
  }

  // --- misc ---------------------------------------------------------------

  fun base64(file: File): String = Base64.encodeToString(file.readBytes(), Base64.NO_WRAP)

  fun deleteTemp(context: Context, path: String) {
    val dir = cacheDir(context)
    if (path.isBlank()) {
      dir.listFiles()?.forEach { it.delete() }
      return
    }
    val file = File(path.removePrefix("file://"))
    // Only ever delete inside our own cache dir.
    if (file.absolutePath.startsWith(dir.absolutePath)) file.delete()
  }
}
