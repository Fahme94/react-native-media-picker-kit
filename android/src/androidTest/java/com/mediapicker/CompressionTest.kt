package com.mediapicker

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.FileOutputStream

/**
 * Compression needs a real JPEG encoder and a real MediaCodec, so it is verified
 * on a device rather than with a JVM unit test. Both fixtures are generated here
 * rather than committed, so there is no binary in the repository and the content
 * can be tuned to what the assertions actually need.
 *
 * ./gradlew :react-native-media-picker-kit:connectedDebugAndroidTest
 */
@RunWith(AndroidJUnit4::class)
class CompressionTest {

  private val context: Context = ApplicationProvider.getApplicationContext()

  @After
  fun clearCache() = MediaUtils.deleteTemp(context, "")

  // --- fixtures -----------------------------------------------------------

  /**
   * Detailed rather than flat: a flat fill encodes to almost nothing, which
   * would leave a fixture too small to exercise a byte budget at all.
   */
  private fun writeTestImage(width: Int, height: Int): File {
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    val paint = Paint()
    var block = 0
    for (y in 0 until height step 8) {
      for (x in 0 until width step 8) {
        paint.color = Color.rgb((x * 7) % 256, (y * 11) % 256, (block * 13) % 256)
        canvas.drawRect(x.toFloat(), y.toFloat(), x + 8f, y + 8f, paint)
        block++
      }
    }
    val file = MediaUtils.newCacheFile(context, "jpg")
    FileOutputStream(file).use { bitmap.compress(Bitmap.CompressFormat.JPEG, 100, it) }
    bitmap.recycle()
    return file
  }

  /** Coarse moving blocks over a ramp: real detail, but still encodable. */
  private fun fillFrame(image: android.media.Image, frame: Int) {
    val y = image.planes[0]
    val u = image.planes[1]
    val v = image.planes[2]
    val width = image.width
    val height = image.height

    val luma = y.buffer
    for (row in 0 until height) {
      for (col in 0 until width) {
        val ramp = ((col shr 3) + (row shr 3) + frame * 4) and 0xFF
        val blocks = if ((((col shr 5) xor (row shr 5)) and 1) == 1) 200 else 40
        luma.position(row * y.rowStride + col * y.pixelStride)
        luma.put(((ramp + blocks) / 2).toByte())
      }
    }
    for (plane in listOf(u, v)) {
      val buffer = plane.buffer
      for (row in 0 until height / 2) {
        for (col in 0 until width / 2) {
          buffer.position(row * plane.rowStride + col * plane.pixelStride)
          buffer.put(((col + row + frame) and 0xFF).toByte())
        }
      }
    }
  }

  private fun writeTestVideo(width: Int, height: Int, frames: Int, fps: Int): File {
    val target = MediaUtils.newCacheFile(context, "mp4")
    val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
      setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
      setInteger(MediaFormat.KEY_BIT_RATE, 6_000_000)
      setInteger(MediaFormat.KEY_FRAME_RATE, fps)
      setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
    }

    val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
    codec.start()
    val muxer = MediaMuxer(target.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

    var track = -1
    var queued = 0
    var done = false
    val info = MediaCodec.BufferInfo()

    while (!done) {
      if (queued <= frames) {
        val index = codec.dequeueInputBuffer(10_000)
        if (index >= 0) {
          val pts = queued * 1_000_000L / fps
          if (queued == frames) {
            codec.queueInputBuffer(index, 0, 0, pts, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
          } else {
            val image = codec.getInputImage(index)
            assertNotNull("encoder gave no flexible input image", image)
            fillFrame(image!!, queued)
            codec.queueInputBuffer(index, 0, width * height * 3 / 2, pts, 0)
          }
          queued++
        }
      }

      when (val out = codec.dequeueOutputBuffer(info, 10_000)) {
        MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
          track = muxer.addTrack(codec.outputFormat)
          muxer.start()
        }
        MediaCodec.INFO_TRY_AGAIN_LATER -> {}
        else -> if (out >= 0) {
          val buffer = codec.getOutputBuffer(out)!!
          if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0 && track >= 0) {
            buffer.position(info.offset)
            buffer.limit(info.offset + info.size)
            muxer.writeSampleData(track, buffer, info)
          }
          codec.releaseOutputBuffer(out, false)
          if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) done = true
        }
      }
    }

    codec.stop()
    codec.release()
    muxer.stop()
    muxer.release()
    return target
  }

  // --- images -------------------------------------------------------------

  @Test
  fun imageIsBroughtUnderTheBudget() {
    val budget = 40L * 1024
    val source = writeTestImage(3000, 2000)
    assertTrue("fixture is already under budget, so this proves nothing", source.length() > budget)

    val out = MediaUtils.compressImage(context, source, "image/jpeg", budget)
    assertTrue("image is over maxImageFileSize: ${out.length()}", out.length() <= budget)

    // Still a real decodable image, not a truncated file that merely fits.
    val decoded = BitmapFactory.decodeFile(out.absolutePath)
    assertNotNull("the compressed image does not decode", decoded)
    assertTrue(decoded.width > 0)
  }

  /** Quality is spent before pixels are, so this budget should cost no resolution. */
  @Test
  fun imageKeepsResolutionWhenQualityAloneSuffices() {
    val source = writeTestImage(1200, 900)
    val out = MediaUtils.compressImage(context, source, "image/jpeg", 200L * 1024)
    assertTrue(out.length() <= 200L * 1024)
    assertEquals(1200 to 900, MediaUtils.imageDimensions(out))
  }

  @Test
  fun imageAlreadyUnderBudgetIsUntouched() {
    val source = writeTestImage(400, 300)
    val out = MediaUtils.compressImage(context, source, "image/jpeg", 8L * 1024 * 1024)
    assertEquals("an under-budget image should be returned as-is", source.absolutePath, out.absolutePath)
  }

  @Test(expected = IllegalStateException::class)
  fun unreachableImageBudgetThrows() {
    // Below what a JPEG header costs, so even the 64px floor cannot reach it.
    MediaUtils.compressImage(context, writeTestImage(3000, 2000), "image/jpeg", 200L)
  }

  // --- video --------------------------------------------------------------

  @Test
  fun videoIsBroughtUnderTheBudget() {
    val budget = 120L * 1024
    val source = writeTestVideo(1280, 720, 90, 30)
    assertTrue("fixture is already under budget, so this proves nothing", source.length() > budget)

    val out = MediaUtils.compressVideo(context, source, budget)
    assertTrue("video is over maxVideoFileSize: ${out.length()}", out.length() <= budget)

    // Still a playable clip of the same length, not a truncated one that fits.
    val meta = MediaUtils.videoMeta(out)
    assertTrue("no video dimensions survived", meta.width > 0 && meta.height > 0)
    assertTrue(
      "the clip was truncated instead of compressed: ${meta.durationMs}ms",
      meta.durationMs in 2500..3500
    )
  }

  @Test
  fun videoAlreadyUnderBudgetIsUntouched() {
    val source = writeTestVideo(320, 240, 30, 30)
    val out = MediaUtils.compressVideo(context, source, 50L * 1024 * 1024)
    assertEquals("an under-budget video should be returned as-is", source.absolutePath, out.absolutePath)
  }
}
