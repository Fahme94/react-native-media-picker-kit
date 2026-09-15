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
import android.webkit.MimeTypeMap
import androidx.exifinterface.media.ExifInterface
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.WritableMap
import com.otaliastudios.transcoder.Transcoder
import com.otaliastudios.transcoder.TranscoderListener
import com.otaliastudios.transcoder.strategy.DefaultAudioStrategy
import com.otaliastudios.transcoder.strategy.DefaultVideoStrategy
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import kotlin.math.sqrt

object MediaUtils {

  private const val CACHE_DIR = "rn_media_picker"

  private const val MIN_JPEG_QUALITY = 10
  private const val MAX_JPEG_QUALITY = 95
  private const val MIN_IMAGE_EDGE = 64

  // Roughly the bits H.264 needs per pixel per frame to still look acceptable.
  private const val VIDEO_BITS_PER_PIXEL = 0.12
  private const val VIDEO_FRAME_RATE = 30
  private const val MAX_AUDIO_BITRATE = 64_000L
  private const val MIN_AUDIO_BITRATE = 24_000L
  private const val MIN_VIDEO_BITRATE = 120_000L
  private const val MIN_VIDEO_EDGE = 144

  // Aim under the limit rather than at it. An encoder treats an average bitrate
  // as something to hover around, and key frames and container overhead do not
  // scale down with it -- targeting the limit exactly measured ~25% over on a
  // short clip.
  private const val SIZE_SAFETY_MARGIN = 0.90

  fun cacheDir(context: Context): File =
    File(context.cacheDir, CACHE_DIR).apply { if (!exists()) mkdirs() }

  fun newCacheFile(context: Context, extension: String): File =
    File(cacheDir(context), "${UUID.randomUUID()}.$extension")

  fun mimeType(context: Context, uri: Uri): String =
    context.contentResolver.getType(uri) ?: "application/octet-stream"

  fun isVideo(mime: String) = mime.startsWith("video/")

  /** For paths that never came from a picker, so there is no resolver to ask. */
  fun mimeForPath(path: String): String {
    val extension = path.substringAfterLast('.', "").lowercase()
    return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
      ?: "application/octet-stream"
  }

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

  /**
   * Re-encode until the file fits in [maxBytes]. Quality is searched first
   * because it costs no pixels; only when even the lowest acceptable quality
   * still overflows does the frame get halved and searched again.
   *
   * Runs after processImage(), so maxWidth/quality have already been honoured
   * and this only takes away what the byte budget demands.
   */
  fun compressImage(context: Context, source: File, mime: String, maxBytes: Long): File {
    if (maxBytes <= 0L || source.length() <= maxBytes) return source
    if (mime == "image/gif") return source // re-encoding would drop the animation

    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(source.absolutePath, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return source

    var width = bounds.outWidth
    var height = bounds.outHeight
    var encoded: ByteArray? = null

    while (true) {
      val decodeOptions = BitmapFactory.Options().apply {
        inSampleSize = sampleSizeFor(bounds.outWidth, bounds.outHeight, width, height)
      }
      val decoded = BitmapFactory.decodeFile(source.absolutePath, decodeOptions) ?: break
      // processImage() strips EXIF whenever it re-encodes, so this is a no-op on
      // an image it touched and the real rotation on one it passed through.
      val bitmap = applyExifRotation(source, decoded)
      encoded = encodeUnderLimit(bitmap, maxBytes)
      bitmap.recycle()
      if (encoded != null || minOf(width, height) / 2 < MIN_IMAGE_EDGE) break
      width /= 2
      height /= 2
    }

    val bytes = encoded ?: throw IllegalStateException(
      "Could not compress the image below $maxBytes bytes"
    )
    val output = newCacheFile(context, "jpg")
    output.writeBytes(bytes)
    deleteIfOurs(context, source)
    return output
  }

  /** Highest JPEG quality that still fits, or null when even the lowest does not. */
  private fun encodeUnderLimit(bitmap: Bitmap, maxBytes: Long): ByteArray? {
    var low = MIN_JPEG_QUALITY
    var high = MAX_JPEG_QUALITY
    var best: ByteArray? = null
    while (low <= high) {
      val quality = (low + high) / 2
      val bytes = ByteArrayOutputStream().use { stream ->
        bitmap.compress(Bitmap.CompressFormat.JPEG, quality, stream)
        stream.toByteArray()
      }
      if (bytes.size <= maxBytes) {
        best = bytes
        low = quality + 1
      } else {
        high = quality - 1
      }
    }
    return best
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

  data class VideoMeta(
    val width: Int,
    val height: Int,
    val durationMs: Long,
    val bitrate: Long,
    val hasAudio: Boolean
  )

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
        bitrate = read(MediaMetadataRetriever.METADATA_KEY_BITRATE),
        hasAudio = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes"
      )
    } catch (_: Exception) {
      VideoMeta(0, 0, 0, 0, false)
    } finally {
      try { retriever.release() } catch (_: Exception) {}
    }
  }

  /**
   * Re-encode to H.264/AAC at a bitrate the clip's own duration can afford.
   * Returns the original untouched when it already fits, and throws when even
   * the floor bitrate cannot get under [maxBytes].
   */
  fun compressVideo(context: Context, source: File, maxBytes: Long): File {
    if (maxBytes <= 0L || source.length() <= maxBytes) return source

    val meta = videoMeta(source)
    val seconds = meta.durationMs / 1000.0
    if (seconds <= 0.0 || meta.width <= 0 || meta.height <= 0) return source

    // An encoder lands near its requested bitrate rather than on it, so the
    // budget gets one correction against what the first pass actually produced.
    var target = (maxBytes * SIZE_SAFETY_MARGIN).toLong()
    repeat(2) {
      val output = transcodeToBudget(context, source, meta, seconds, target)
        ?: return source // the transcoder found nothing worth doing
      if (output.length() <= maxBytes) {
        deleteIfOurs(context, source)
        return output
      }
      // Scale the next request by how far this pass actually missed, keeping the
      // margin so the correction lands inside the limit rather than back on it.
      target = (target * (maxBytes * SIZE_SAFETY_MARGIN) / output.length()).toLong()
      output.delete()
    }
    throw IllegalStateException("Could not compress the video below $maxBytes bytes")
  }

  private fun transcodeToBudget(
    context: Context,
    source: File,
    meta: VideoMeta,
    seconds: Double,
    budget: Long
  ): File? {
    val totalBitrate = (budget * 8 / seconds).toLong()
    val audioBitrate = if (meta.hasAudio) {
      (totalBitrate / 4).coerceIn(MIN_AUDIO_BITRATE, MAX_AUDIO_BITRATE)
    } else {
      0L
    }
    val videoBitrate = (totalBitrate - audioBitrate).coerceAtLeast(MIN_VIDEO_BITRATE)

    val output = newCacheFile(context, "mp4")
    val builder = Transcoder.into(output.absolutePath)
      .addDataSource(source.absolutePath)
      // Required: the builder refuses to build without one. The callbacks stay
      // empty on purpose -- they are posted to the main looper and can land
      // after transcode() has already returned, so the outcome is read from the
      // future and the output file instead, which cannot race.
      .setListener(object : TranscoderListener {
        override fun onTranscodeProgress(progress: Double) = Unit
        override fun onTranscodeCompleted(successCode: Int) = Unit
        override fun onTranscodeCanceled() = Unit
        override fun onTranscodeFailed(exception: Throwable) = Unit
      })
      .setVideoTrackStrategy(
        DefaultVideoStrategy.atMost(minorEdgeFor(meta, videoBitrate))
          .bitRate(videoBitrate)
          .frameRate(VIDEO_FRAME_RATE)
          .build()
      )
    if (meta.hasAudio) {
      builder.setAudioTrackStrategy(
        DefaultAudioStrategy.builder().bitRate(audioBitrate).build()
      )
    }

    try {
      // Already on the worker thread, so block rather than juggle a listener.
      // TranscodeEngine rethrows, so a failure surfaces as ExecutionException.
      builder.transcode().get()
    } catch (e: Exception) {
      output.delete()
      throw IllegalStateException(
        e.cause?.message ?: e.message ?: "Video compression failed", e
      )
    }

    // A transcoder that judged the work unnecessary leaves nothing behind.
    if (!output.exists() || output.length() == 0L) {
      output.delete()
      return null
    }
    return output
  }

  /**
   * The largest frame the video budget can carry, expressed as a limit on the
   * shorter edge — which is what AtMostResizer measures when handed a single
   * dimension.
   */
  private fun minorEdgeFor(meta: VideoMeta, videoBitrate: Long): Int {
    val minor = minOf(meta.width, meta.height)
    val major = maxOf(meta.width, meta.height)
    val pixels = videoBitrate / (VIDEO_BITS_PER_PIXEL * VIDEO_FRAME_RATE)
    val wanted = sqrt(pixels * minor / major).toInt().coerceAtLeast(MIN_VIDEO_EDGE)

    // DefaultVideoStrategy passes a track straight through when the frame is not
    // shrinking, and that test ignores bitrate — so asking for the size the
    // source already has would hand back the original file unchanged.
    val ceiling = (minor - 2).coerceAtLeast(2)
    val edge = minOf(wanted, ceiling)
    return if (edge % 2 == 0) edge else edge - 1
  }

  // --- misc ---------------------------------------------------------------

  fun base64(file: File): String = Base64.encodeToString(file.readBytes(), Base64.NO_WRAP)

  /**
   * Replacing a file means dropping the one it replaced — but compressMedia()
   * takes any path the caller hands it, so only this module's own cache files
   * are ever removed.
   */
  private fun deleteIfOurs(context: Context, file: File) {
    if (file.absolutePath.startsWith(cacheDir(context).absolutePath)) file.delete()
  }

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
