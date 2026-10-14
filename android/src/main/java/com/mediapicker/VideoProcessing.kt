package com.mediapicker

import android.content.Context
import android.media.MediaMetadataRetriever
import android.os.CancellationSignal
import com.otaliastudios.transcoder.Transcoder
import com.otaliastudios.transcoder.TranscoderListener
import com.otaliastudios.transcoder.strategy.DefaultAudioStrategy
import com.otaliastudios.transcoder.strategy.DefaultVideoStrategy
import java.io.File
import kotlin.math.sqrt

/** Reading video metadata, and transcoding a clip down to a byte budget. */
object VideoProcessing {

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

  // A correction pass would otherwise send a progress bar back to zero, so the
  // first pass owns most of the range and the second finishes it.
  private val PASS_PROGRESS_RANGE = listOf(0.0 to 0.85, 0.85 to 1.0)

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
  fun compressVideo(
    context: Context,
    source: File,
    maxBytes: Long,
    minBytes: Long = 0L,
    cancel: CancellationSignal? = null,
    onProgress: (Double) -> Unit = {}
  ): File {
    if (maxBytes <= 0L || source.length() <= maxBytes) return source
    // Over budget, but not by enough to be worth a whole transcode. Returns a
    // file that is still over its budget, deliberately.
    if (minBytes > 0L && source.length() < minBytes) return source

    val meta = videoMeta(source)
    val seconds = meta.durationMs / 1000.0
    if (seconds <= 0.0 || meta.width <= 0 || meta.height <= 0) return source

    // An encoder lands near its requested bitrate rather than on it, so the
    // budget gets one correction against what the first pass actually produced.
    var target = (maxBytes * SIZE_SAFETY_MARGIN).toLong()
    var produced = 0L
    repeat(2) { pass ->
      val (from, to) = PASS_PROGRESS_RANGE[pass]
      // A cancel and a transcoder that found nothing to do look the same here:
      // both mean hand back the original. The caller tells them apart by asking
      // the signal, which is also what decides whether to report it as skipped.
      val output = transcodeToBudget(context, source, meta, seconds, target, cancel) {
        onProgress(from + (to - from) * it)
      } ?: return source
      if (output.length() <= maxBytes) {
        onProgress(1.0)
        MediaFiles.deleteIfOurs(context, source)
        return output
      }
      // Scale the next request by how far this pass actually missed, keeping the
      // margin so the correction lands inside the limit rather than back on it.
      produced = output.length()
      target = (target * (maxBytes * SIZE_SAFETY_MARGIN) / produced).toLong()
      output.delete()
    }
    // How far it got matters when this fails: how much an encoder overshoots its
    // requested bitrate is device-specific, so the gap is the useful diagnostic.
    throw IllegalStateException(
      "Could not compress the video below $maxBytes bytes; closest was $produced"
    )
  }

  private fun transcodeToBudget(
    context: Context,
    source: File,
    meta: VideoMeta,
    seconds: Double,
    budget: Long,
    cancel: CancellationSignal?,
    onProgress: (Double) -> Unit
  ): File? {
    if (cancel?.isCanceled == true) return null

    val totalBitrate = (budget * 8 / seconds).toLong()
    val audioBitrate = if (meta.hasAudio) {
      (totalBitrate / 4).coerceIn(MIN_AUDIO_BITRATE, MAX_AUDIO_BITRATE)
    } else {
      0L
    }
    val videoBitrate = (totalBitrate - audioBitrate).coerceAtLeast(MIN_VIDEO_BITRATE)

    val output = MediaFiles.newCacheFile(context, "mp4")
    val builder = Transcoder.into(output.absolutePath)
      .addDataSource(source.absolutePath)
      // Required: the builder refuses to build without one. The callbacks stay
      // empty on purpose -- they are posted to the main looper and can land
      // after transcode() has already returned, so the outcome is read from the
      // future and the output file instead, which cannot race.
      .setListener(object : TranscoderListener {
        // Progress is the one callback worth reading. The others stay empty:
        // they are posted to the main looper and can land after transcode() has
        // already returned, so the outcome is still read from the future and the
        // output file, which cannot race.
        override fun onTranscodeProgress(progress: Double) = onProgress(progress)
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

    val future = builder.transcode()
    // TranscodeEngine treats an interrupt as a cancel rather than a failure, so
    // cancelling the future is the supported way to stop it part-way.
    cancel?.setOnCancelListener { future.cancel(true) }
    try {
      // Already on the worker thread, so block rather than juggle a listener.
      // TranscodeEngine rethrows, so a failure surfaces as ExecutionException.
      future.get()
    } catch (e: Exception) {
      output.delete()
      // A cancelled job is not a failed one: the caller asked for this, and
      // returning null hands the original back instead of raising.
      if (cancel?.isCanceled == true) return null
      throw IllegalStateException(
        e.cause?.message ?: e.message ?: "Video compression failed", e
      )
    } finally {
      cancel?.setOnCancelListener(null)
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
}
