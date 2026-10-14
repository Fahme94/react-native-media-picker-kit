package com.mediapicker

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import com.canhub.cropper.CropImageContract
import com.canhub.cropper.CropImageContractOptions
import com.canhub.cropper.CropImageOptions
import com.canhub.cropper.CropImageView
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableMap
import java.io.File

/** The crop screen, and the cropped file it hands back. */
internal class Cropper(private val context: Context) {

  class Cropped(val file: File, val cropRect: WritableMap?)

  fun intent(activity: Activity, source: Uri, options: ReadableMap): Intent {
    val cropWidth = options.intOr("cropWidth", 0)
    val cropHeight = options.intOr("cropHeight", 0)
    val freeStyle = options.flag("freeStyleCropEnabled")
    val circle = options.flag("cropperCircleOverlay")
    val output = MediaFiles.newCacheFile(context, "jpg")

    val cropOptions = CropImageOptions().apply {
      activityTitle = options.getString("cropperToolbarTitle") ?: "Edit Photo"
      // Documented as a cross-platform option, so the Android confirm action has
      // to carry it too; left unset the cropper falls back to its own "CROP".
      options.getString("cropperChooseText")?.let { cropMenuCropButtonTitle = it }
      cropShape = if (circle) CropImageView.CropShape.OVAL else CropImageView.CropShape.RECTANGLE
      guidelines = CropImageView.Guidelines.ON_TOUCH
      customOutputUri = Uri.fromFile(output)
      outputCompressFormat = Bitmap.CompressFormat.JPEG
      outputCompressQuality = (options.doubleOr("quality", 1.0) * 100).toInt().coerceIn(1, 100)
      imageSourceIncludeGallery = false
      imageSourceIncludeCamera = false

      if (cropWidth > 0 && cropHeight > 0) {
        fixAspectRatio = !freeStyle
        aspectRatioX = cropWidth
        aspectRatioY = cropHeight
        outputRequestWidth = cropWidth
        outputRequestHeight = cropHeight
        // outputRequestWidth/Height are inert on their own: the default
        // outputRequestSizeOptions is NONE, which makes the cropper ignore them
        // and emit the crop at source resolution. A locked aspect ratio can be
        // resized exactly; a free-form crop has to fit inside to avoid stretching.
        outputRequestSizeOptions = if (freeStyle) {
          CropImageView.RequestSizeOptions.RESIZE_INSIDE
        } else {
          CropImageView.RequestSizeOptions.RESIZE_EXACT
        }
      }

      parseColor(options.getString("cropperToolbarColor"))?.let { toolbarColor = it }
      parseColor(options.getString("cropperActiveWidgetColor"))?.let { activityMenuIconColor = it }
    }

    return CropImageContract().createIntent(activity, CropImageContractOptions(source, cropOptions))
  }

  /** Throws with the reason when the cropper did not produce a file. */
  fun result(resultCode: Int, data: Intent): Cropped {
    val result = CropImageContract().parseResult(resultCode, data)
    if (!result.isSuccessful) {
      throw IllegalStateException(result.error?.message ?: "Cropping failed")
    }
    val path = result.uriContent?.path
      ?: throw IllegalStateException("Cropper returned no file")

    val cropRect = result.cropRect?.let {
      Arguments.createMap().apply {
        putInt("x", it.left)
        putInt("y", it.top)
        putInt("width", it.width())
        putInt("height", it.height())
      }
    }
    return Cropped(File(path), cropRect)
  }

  private fun parseColor(hex: String?): Int? = try {
    if (hex.isNullOrBlank()) null else Color.parseColor(hex)
  } catch (_: Exception) {
    null
  }
}
