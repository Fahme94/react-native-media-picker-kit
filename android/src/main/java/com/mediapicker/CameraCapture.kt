package com.mediapicker

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.MediaStore
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import com.facebook.react.bridge.ReadableMap
import java.io.File

/** The system camera app, launched to write into a file this module owns. */
internal class CameraCapture(private val context: Context) {

  /**
   * The capture intents need no permission of their own. Android does refuse
   * them when the *app* declares CAMERA and the user has not granted it, and
   * apps inherit that declaration from other libraries, so check for it rather
   * than assume this library's empty permission list is the whole story.
   */
  fun permissionMissing(activity: Activity): Boolean {
    val declared = try {
      val info = activity.packageManager
        .getPackageInfo(activity.packageName, PackageManager.GET_PERMISSIONS)
      info.requestedPermissions?.contains(Manifest.permission.CAMERA) == true
    } catch (_: Exception) {
      false
    }
    if (!declared) return false
    return ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) !=
      PackageManager.PERMISSION_GRANTED
  }

  fun intent(options: ReadableMap, isVideo: Boolean, output: File): Intent = Intent(
    if (isVideo) MediaStore.ACTION_VIDEO_CAPTURE else MediaStore.ACTION_IMAGE_CAPTURE
  ).apply {
    putExtra(
      MediaStore.EXTRA_OUTPUT,
      FileProvider.getUriForFile(context, fileProviderAuthority(), output)
    )
    addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)

    if (isVideo) {
      val limit = options.intOr("durationLimit", 0)
      if (limit > 0) putExtra(MediaStore.EXTRA_DURATION_LIMIT, limit)
      putExtra(
        MediaStore.EXTRA_VIDEO_QUALITY,
        if (options.getString("videoQuality") == "low") 0 else 1
      )
    }
    if (options.getString("cameraType") == "front") {
      // There is no standard extra for lens selection; these are the hints the
      // common camera apps read, and any of them may be ignored.
      putExtra("android.intent.extras.CAMERA_FACING", 1)
      putExtra("android.intent.extras.LENS_FACING_FRONT", 1)
      putExtra("android.intent.extra.USE_FRONT_CAMERA", true)
    }
  }

  private fun fileProviderAuthority() = "${context.packageName}.mediapickerprovider"

  /**
   * What the camera produced after it reported RESULT_OK, processed and ready
   * to report, or null when it produced nothing and the capture is a cancel.
   */
  fun result(output: File?, isVideo: Boolean, data: Intent?, options: ReadableMap): Processed? {
    // Our own output file wins whenever the camera actually wrote to it.
    // Camera apps routinely echo the EXTRA_OUTPUT uri back in data.data, so
    // treating a non-null data.data as "the camera ignored EXTRA_OUTPUT"
    // would delete the very file that uri points at.
    val written = output?.takeIf { it.exists() && it.length() > 0L }
    val returned = data?.data

    val file: File
    val mime: String
    when {
      written != null -> {
        file = written
        mime = if (isVideo) "video/mp4" else "image/jpeg"
      }
      returned != null -> {
        // The camera ignored EXTRA_OUTPUT and kept the media somewhere of
        // its own choosing, so copy it into our cache before reporting it.
        output?.delete()
        mime = MediaFiles.mimeType(context, returned)
          .takeIf { it != "application/octet-stream" }
          ?: if (isVideo) "video/mp4" else "image/jpeg"
        file = MediaFiles.copyToCache(context, returned, MediaFiles.extensionFor(mime, false))
        if (!file.exists() || file.length() == 0L) {
          file.delete()
          return null
        }
      }
      else -> {
        // RESULT_OK with nothing written is a cancel in every way the
        // caller cares about.
        output?.delete()
        return null
      }
    }
    return process(file, mime, options)
  }

  private fun process(source: File, mime: String, options: ReadableMap): Processed {
    if (MediaFiles.isVideo(mime)) return Processed(source, mime, source.name)

    val forceJpg = options.flag("forceJpg", true)
    val file = ImageProcessing.processImage(
      context = context,
      source = source,
      mime = mime,
      maxWidth = options.intOr("maxWidth", 0),
      maxHeight = options.intOr("maxHeight", 0),
      quality = options.doubleOr("quality", 1.0),
      forceJpg = forceJpg
    )
    return Processed(file, if (forceJpg) "image/jpeg" else mime, file.name)
  }
}
