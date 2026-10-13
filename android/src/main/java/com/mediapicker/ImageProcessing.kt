package com.mediapicker

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import androidx.exifinterface.media.ExifInterface
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.WritableMap
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream

/** Resizing, re-encoding and compressing still images, and reading what they carry. */
object ImageProcessing {

  private const val MIN_JPEG_QUALITY = 10
  private const val MAX_JPEG_QUALITY = 95
  private const val MIN_IMAGE_EDGE = 64

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

    // Sized upright: the bitmap is rotated below, so sizing it by the stored
    // (sensor-oriented) pixels would squash every portrait camera shot.
    val (srcW, srcH) = imageDimensions(source)
    if (srcW <= 0 || srcH <= 0) return source

    val targetW = if (maxWidth > 0) maxWidth else srcW
    val targetH = if (maxHeight > 0) maxHeight else srcH
    val scale = minOf(
      targetW.toDouble() / srcW,
      targetH.toDouble() / srcH,
      1.0
    )

    val decodeOptions = BitmapFactory.Options().apply {
      inSampleSize = sampleSizeFor(srcW, srcH, targetW, targetH)
    }
    var bitmap = BitmapFactory.decodeFile(source.absolutePath, decodeOptions) ?: return source
    bitmap = applyExifRotation(source, bitmap)

    if (scale < 1.0) {
      val w = (srcW * scale).toInt().coerceAtLeast(1)
      val h = (srcH * scale).toInt().coerceAtLeast(1)
      if (w != bitmap.width || h != bitmap.height) {
        val scaled = Bitmap.createScaledBitmap(bitmap, w, h, true)
        if (scaled != bitmap) bitmap.recycle()
        bitmap = scaled
      }
    }

    val usePng = !forceJpg && mime == "image/png"
    val output = MediaFiles.newCacheFile(context, if (usePng) "png" else "jpg")
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

  private fun exifDegrees(file: File): Float = try {
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

  private fun applyExifRotation(file: File, bitmap: Bitmap): Bitmap {
    val degrees = exifDegrees(file)
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
  fun compressImage(
    context: Context,
    source: File,
    mime: String,
    maxBytes: Long,
    minBytes: Long = 0L
  ): File {
    if (maxBytes <= 0L || source.length() <= maxBytes) return source
    // Over budget, but not by enough to be worth the work the caller asked us
    // to avoid. Returns a file that is still over its budget, deliberately.
    if (minBytes > 0L && source.length() < minBytes) return source
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
    val output = MediaFiles.newCacheFile(context, "jpg")
    output.writeBytes(bytes)
    MediaFiles.deleteIfOurs(context, source)
    return output
  }

  /** Highest JPEG quality that still fits, or null when even the lowest does not. */
  private fun encodeUnderLimit(bitmap: Bitmap, maxBytes: Long): ByteArray? {
    fun encode(quality: Int) = ByteArrayOutputStream().use { stream ->
      bitmap.compress(Bitmap.CompressFormat.JPEG, quality, stream)
      stream.toByteArray()
    }

    // The floor first: when even it overflows, no quality will fit at this size,
    // and finding that out by bisection would cost a whole search per halving.
    var best = encode(MIN_JPEG_QUALITY).takeIf { it.size <= maxBytes } ?: return null
    var low = MIN_JPEG_QUALITY + 1
    var high = MAX_JPEG_QUALITY
    while (low <= high) {
      val quality = (low + high) / 2
      val bytes = encode(quality)
      if (bytes.size <= maxBytes) {
        best = bytes
        low = quality + 1
      } else {
        high = quality - 1
      }
    }
    return best
  }

  /** Upright size — what the image displays as once its EXIF rotation is applied. */
  fun imageDimensions(file: File): Pair<Int, Int> {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.absolutePath, bounds)
    val degrees = exifDegrees(file)
    val quarterTurn = degrees == 90f || degrees == 270f
    return if (quarterTurn) bounds.outHeight to bounds.outWidth else bounds.outWidth to bounds.outHeight
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
}
