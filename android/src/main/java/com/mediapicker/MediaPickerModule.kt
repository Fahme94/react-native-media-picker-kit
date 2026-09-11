package com.mediapicker

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.Uri
import android.provider.MediaStore
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import com.canhub.cropper.CropImageContract
import com.canhub.cropper.CropImageContractOptions
import com.canhub.cropper.CropImageOptions
import com.canhub.cropper.CropImageView
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableArray
import com.facebook.react.bridge.WritableMap
import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.modules.core.PermissionAwareActivity
import com.facebook.react.modules.core.PermissionListener
import java.io.File
import java.util.concurrent.Executors

@ReactModule(name = MediaPickerModule.NAME)
class MediaPickerModule(private val reactContext: ReactApplicationContext) :
  NativeMediaPickerSpec(reactContext) {

  companion object {
    const val NAME = "MediaPicker"
    private const val RC_PICK = 51001
    private const val RC_CROP = 51002
    private const val RC_CAPTURE = 51003
    private const val RC_CAMERA_PERMISSION = 51004
    // PickMultipleVisualMedia rejects unbounded requests, so "unlimited" is capped.
    private const val UNLIMITED_CAP = 100
  }

  private val worker = Executors.newSingleThreadExecutor()

  private var pendingPromise: Promise? = null
  private var pendingOptions: ReadableMap? = null
  private var pendingOriginalUri: String? = null
  private var pendingCaptureFile: File? = null
  private var pendingCaptureIsVideo = false

  private val activityListener = object : com.facebook.react.bridge.BaseActivityEventListener() {
    override fun onActivityResult(activity: Activity?, requestCode: Int, resultCode: Int, data: Intent?) {
      when (requestCode) {
        RC_PICK -> handlePickResult(resultCode, data)
        RC_CAPTURE -> handleCaptureResult(resultCode, data)
        RC_CROP -> handleCropResult(resultCode, data)
      }
    }
  }

  init {
    reactContext.addActivityEventListener(activityListener)
  }

  override fun getName() = NAME

  override fun invalidate() {
    reactContext.removeActivityEventListener(activityListener)
    worker.shutdown()
    super.invalidate()
  }

  // --- JS surface ---------------------------------------------------------

  override fun pickMedia(options: ReadableMap, promise: Promise) {
    val activity = currentActivity
      ?: return promise.resolve(errorResult("others", "No foreground activity"))
    if (pendingPromise != null) {
      return promise.resolve(errorResult("picker_busy", "A picker is already open"))
    }

    pendingPromise = promise
    pendingOptions = options
    try {
      activity.startActivityForResult(buildPickIntent(activity, options), RC_PICK)
    } catch (e: Exception) {
      finish(errorResult("others", e.message ?: "Could not open the picker"))
    }
  }

  override fun captureMedia(options: ReadableMap, promise: Promise) {
    val activity = currentActivity
      ?: return promise.resolve(errorResult("others", "No foreground activity"))
    if (pendingPromise != null) {
      return promise.resolve(errorResult("picker_busy", "A picker is already open"))
    }

    pendingPromise = promise
    pendingOptions = options

    // The capture intents need no permission of their own. Android does refuse
    // them when the *app* declares CAMERA and the user has not granted it, and
    // apps inherit that declaration from other libraries, so check for it rather
    // than assume this library's empty permission list is the whole story.
    if (cameraPermissionMissing(activity)) {
      requestCameraPermission(activity)
    } else {
      launchCapture(activity)
    }
  }

  override fun cropImage(options: ReadableMap, promise: Promise) {
    val activity = currentActivity
      ?: return promise.resolve(errorResult("others", "No foreground activity"))
    if (pendingPromise != null) {
      return promise.resolve(errorResult("picker_busy", "A picker is already open"))
    }
    val path = options.getString("path")
    if (path.isNullOrBlank()) {
      return promise.resolve(errorResult("invalid_options", "path is required"))
    }

    pendingPromise = promise
    pendingOptions = options
    pendingOriginalUri = path
    startCrop(activity, Uri.fromFile(File(path.removePrefix("file://"))), options)
  }

  override fun cleanTempFiles(path: String, promise: Promise) {
    worker.execute {
      try {
        MediaUtils.deleteTemp(reactContext, path)
        promise.resolve(null)
      } catch (e: Exception) {
        promise.reject("clean_failed", e.message, e)
      }
    }
  }

  // --- picking ------------------------------------------------------------

  private fun buildPickIntent(activity: Activity, options: ReadableMap): Intent {
    val mediaType = options.getString("mediaType") ?: "photo"
    val limit = if (options.hasKey("selectionLimit")) options.getInt("selectionLimit") else 1

    val visualType = when (mediaType) {
      "photo" -> ActivityResultContracts.PickVisualMedia.ImageOnly
      "video" -> ActivityResultContracts.PickVisualMedia.VideoOnly
      else -> ActivityResultContracts.PickVisualMedia.ImageAndVideo
    }

    if (ActivityResultContracts.PickVisualMedia.isPhotoPickerAvailable(activity)) {
      val request = PickVisualMediaRequest.Builder().setMediaType(visualType).build()
      return if (limit == 1) {
        ActivityResultContracts.PickVisualMedia().createIntent(activity, request)
      } else {
        val max = if (limit <= 0) UNLIMITED_CAP else limit
        ActivityResultContracts.PickMultipleVisualMedia(max).createIntent(activity, request)
      }
    }

    // Pre-photo-picker devices: Storage Access Framework. Still no permission needed.
    val mimes = readStringArray(options, "restrictMimeTypes").ifEmpty {
      when (mediaType) {
        "photo" -> listOf("image/*")
        "video" -> listOf("video/*")
        else -> listOf("image/*", "video/*")
      }
    }
    return Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
      addCategory(Intent.CATEGORY_OPENABLE)
      type = if (mimes.size == 1) mimes[0] else "*/*"
      if (mimes.size > 1) putExtra(Intent.EXTRA_MIME_TYPES, mimes.toTypedArray())
      putExtra(Intent.EXTRA_ALLOW_MULTIPLE, limit != 1)
      addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
  }

  private fun handlePickResult(resultCode: Int, data: Intent?) {
    if (resultCode != Activity.RESULT_OK || data == null) {
      return finish(cancelledResult())
    }

    val uris = mutableListOf<Uri>()
    data.clipData?.let { clip ->
      for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
    } ?: data.data?.let { uris.add(it) }

    if (uris.isEmpty()) return finish(cancelledResult())

    val options = pendingOptions ?: return finish(errorResult("others", "Lost picker options"))

    worker.execute {
      try {
        val files = uris.map { uri -> copyAndProcess(uri, options) }
        deliver(files, uris.map { it.toString() }, options)
      } catch (e: Exception) {
        finish(errorResult("cannot_process_asset", e.message ?: "Could not read the selected media"))
      }
    }
  }

  /**
   * Single exit for both picking and capturing: hand a single still image to the
   * cropper when cropping was asked for, otherwise resolve with the assets. Runs
   * on the worker thread; the cropper is dispatched back to the UI thread.
   */
  private fun deliver(files: List<Processed>, originalUris: List<String?>, options: ReadableMap) {
    val wantsCrop = options.hasKey("cropping") && options.getBoolean("cropping")

    if (wantsCrop && files.size == 1 && !MediaUtils.isVideo(files[0].mime)) {
      val activity = currentActivity
        ?: return finish(errorResult("others", "No foreground activity"))
      pendingOriginalUri = originalUris.firstOrNull()
      activity.runOnUiThread {
        startCrop(activity, Uri.fromFile(files[0].file), options)
      }
      return
    }

    val assets = Arguments.createArray()
    files.forEachIndexed { index, processed ->
      assets.pushMap(buildAsset(processed, originalUris.getOrNull(index), options, null))
    }
    finish(successResult(assets))
  }

  private data class Processed(val file: File, val mime: String, val displayName: String)

  private fun copyAndProcess(uri: Uri, options: ReadableMap): Processed {
    val mime = MediaUtils.mimeType(reactContext, uri)
    val forceJpg = !options.hasKey("forceJpg") || options.getBoolean("forceJpg")
    val extension = MediaUtils.extensionFor(mime, forceJpg)
    val name = MediaUtils.displayName(reactContext, uri, "media.$extension")

    var file = MediaUtils.copyToCache(reactContext, uri, extension)

    if (!MediaUtils.isVideo(mime)) {
      file = MediaUtils.processImage(
        context = reactContext,
        source = file,
        mime = mime,
        maxWidth = intOr(options, "maxWidth", 0),
        maxHeight = intOr(options, "maxHeight", 0),
        quality = doubleOr(options, "quality", 1.0),
        forceJpg = forceJpg
      )
    }

    val finalMime = if (!MediaUtils.isVideo(mime) && forceJpg && mime != "image/gif") "image/jpeg" else mime
    // The gallery's display name still carries the source extension, so a
    // re-encoded PNG would be reported as "shot.png" while both the file on
    // disk and `type` say JPEG. Report the extension the bytes actually have.
    return Processed(file, finalMime, MediaUtils.withExtension(name, file.extension))
  }

  // --- capture ------------------------------------------------------------

  private fun cameraPermissionMissing(activity: Activity): Boolean {
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

  private fun requestCameraPermission(activity: Activity) {
    val permissionAware = activity as? PermissionAwareActivity
      ?: return finish(errorResult("permission", "Activity cannot request permissions"))

    permissionAware.requestPermissions(
      arrayOf(Manifest.permission.CAMERA),
      RC_CAMERA_PERMISSION,
      PermissionListener { requestCode, _, grantResults ->
        if (requestCode == RC_CAMERA_PERMISSION) {
          val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
          if (!granted) {
            finish(errorResult("permission", "Camera permission was denied"))
          } else {
            val current = currentActivity
            if (current == null) {
              finish(errorResult("others", "No foreground activity"))
            } else {
              launchCapture(current)
            }
          }
        }
        true
      }
    )
  }

  private fun launchCapture(activity: Activity) {
    val options = pendingOptions ?: return finish(errorResult("others", "Lost picker options"))
    val isVideo = options.getString("mediaType") == "video"
    val output = MediaUtils.newCacheFile(reactContext, if (isVideo) "mp4" else "jpg")

    pendingCaptureFile = output
    pendingCaptureIsVideo = isVideo

    val intent = Intent(
      if (isVideo) MediaStore.ACTION_VIDEO_CAPTURE else MediaStore.ACTION_IMAGE_CAPTURE
    ).apply {
      putExtra(
        MediaStore.EXTRA_OUTPUT,
        FileProvider.getUriForFile(reactContext, fileProviderAuthority(), output)
      )
      addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)

      if (isVideo) {
        val limit = intOr(options, "durationLimit", 0)
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

    try {
      // No <queries> entry is needed: package visibility filters resolveActivity,
      // not the ability to start an implicit intent.
      activity.startActivityForResult(intent, RC_CAPTURE)
    } catch (e: ActivityNotFoundException) {
      finish(errorResult("camera_unavailable", "No camera app is available"))
    } catch (e: Exception) {
      finish(errorResult("others", e.message ?: "Could not open the camera"))
    }
  }

  private fun fileProviderAuthority() = "${reactContext.packageName}.mediapickerprovider"

  private fun handleCaptureResult(resultCode: Int, data: Intent?) {
    val output = pendingCaptureFile
    val isVideo = pendingCaptureIsVideo

    if (resultCode != Activity.RESULT_OK) {
      output?.delete()
      return finish(cancelledResult())
    }

    val options = pendingOptions ?: return finish(errorResult("others", "Lost picker options"))

    worker.execute {
      try {
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
            mime = MediaUtils.mimeType(reactContext, returned)
              .takeIf { it != "application/octet-stream" }
              ?: if (isVideo) "video/mp4" else "image/jpeg"
            file = MediaUtils.copyToCache(reactContext, returned, MediaUtils.extensionFor(mime, false))
            if (!file.exists() || file.length() == 0L) {
              file.delete()
              return@execute finish(cancelledResult())
            }
          }
          else -> {
            // RESULT_OK with nothing written is a cancel in every way the
            // caller cares about.
            output?.delete()
            return@execute finish(cancelledResult())
          }
        }

        deliver(listOf(processCaptured(file, mime, options)), listOf(null), options)
      } catch (e: Exception) {
        finish(errorResult("cannot_process_asset", e.message ?: "Could not read the capture"))
      }
    }
  }

  private fun processCaptured(source: File, mime: String, options: ReadableMap): Processed {
    if (MediaUtils.isVideo(mime)) return Processed(source, mime, source.name)

    val forceJpg = !options.hasKey("forceJpg") || options.getBoolean("forceJpg")
    val file = MediaUtils.processImage(
      context = reactContext,
      source = source,
      mime = mime,
      maxWidth = intOr(options, "maxWidth", 0),
      maxHeight = intOr(options, "maxHeight", 0),
      quality = doubleOr(options, "quality", 1.0),
      forceJpg = forceJpg
    )
    return Processed(file, if (forceJpg) "image/jpeg" else mime, file.name)
  }

  // --- cropping -----------------------------------------------------------

  private fun startCrop(activity: Activity, source: Uri, options: ReadableMap) {
    val cropWidth = intOr(options, "cropWidth", 0)
    val cropHeight = intOr(options, "cropHeight", 0)
    val freeStyle = options.hasKey("freeStyleCropEnabled") && options.getBoolean("freeStyleCropEnabled")
    val circle = options.hasKey("cropperCircleOverlay") && options.getBoolean("cropperCircleOverlay")
    val output = MediaUtils.newCacheFile(reactContext, "jpg")

    val cropOptions = CropImageOptions().apply {
      activityTitle = options.getString("cropperToolbarTitle") ?: "Edit Photo"
      // Documented as a cross-platform option, so the Android confirm action has
      // to carry it too; left unset the cropper falls back to its own "CROP".
      options.getString("cropperChooseText")?.let { cropMenuCropButtonTitle = it }
      cropShape = if (circle) CropImageView.CropShape.OVAL else CropImageView.CropShape.RECTANGLE
      guidelines = CropImageView.Guidelines.ON_TOUCH
      customOutputUri = Uri.fromFile(output)
      outputCompressFormat = android.graphics.Bitmap.CompressFormat.JPEG
      outputCompressQuality = (doubleOr(options, "quality", 1.0) * 100).toInt().coerceIn(1, 100)
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

    try {
      val intent = CropImageContract().createIntent(
        activity,
        CropImageContractOptions(source, cropOptions)
      )
      activity.startActivityForResult(intent, RC_CROP)
    } catch (e: Exception) {
      finish(errorResult("crop_failed", e.message ?: "Could not open the cropper"))
    }
  }

  private fun handleCropResult(resultCode: Int, data: Intent?) {
    if (resultCode != Activity.RESULT_OK || data == null) {
      return finish(cancelledResult())
    }

    val options = pendingOptions ?: return finish(errorResult("others", "Lost picker options"))
    worker.execute {
      try {
        val result = CropImageContract().parseResult(resultCode, data)
        if (!result.isSuccessful) {
          return@execute finish(
            errorResult("crop_failed", result.error?.message ?: "Cropping failed")
          )
        }
        val path = result.uriContent?.path
          ?: return@execute finish(errorResult("crop_failed", "Cropper returned no file"))

        val file = File(path)
        val cropRect = result.cropRect?.let {
          Arguments.createMap().apply {
            putInt("x", it.left)
            putInt("y", it.top)
            putInt("width", it.width())
            putInt("height", it.height())
          }
        }
        val processed = Processed(file, "image/jpeg", file.name)
        val assets = Arguments.createArray()
        assets.pushMap(buildAsset(processed, pendingOriginalUri, options, cropRect))
        finish(successResult(assets))
      } catch (e: Exception) {
        finish(errorResult("crop_failed", e.message ?: "Cropping failed"))
      }
    }
  }

  // --- result building ----------------------------------------------------

  private fun buildAsset(
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

    if (MediaUtils.isVideo(processed.mime)) {
      val meta = MediaUtils.videoMeta(file)
      map.putInt("width", meta.width)
      map.putInt("height", meta.height)
      map.putDouble("duration", meta.durationMs.toDouble())
      map.putDouble("bitrate", meta.bitrate.toDouble())
    } else {
      val (w, h) = MediaUtils.imageDimensions(file)
      map.putInt("width", w)
      map.putInt("height", h)
      if (options.hasKey("includeExif") && options.getBoolean("includeExif")) {
        map.putMap("exif", MediaUtils.exifMap(file))
      }
      if (options.hasKey("includeBase64") && options.getBoolean("includeBase64")) {
        map.putString("base64", MediaUtils.base64(file))
      }
    }

    if (options.hasKey("includeExtra") && options.getBoolean("includeExtra")) {
      map.putString("id", processed.displayName)
      map.putString("timestamp", file.lastModified().toString())
    }
    originalUri?.let { map.putString("originalPath", it) }
    cropRect?.let { map.putMap("cropRect", it) }
    return map
  }

  private fun successResult(assets: WritableArray): WritableMap = Arguments.createMap().apply {
    putBoolean("didCancel", false)
    putArray("assets", assets)
  }

  private fun cancelledResult(): WritableMap = Arguments.createMap().apply {
    putBoolean("didCancel", true)
    putArray("assets", Arguments.createArray())
  }

  private fun errorResult(code: String, message: String): WritableMap = Arguments.createMap().apply {
    putBoolean("didCancel", false)
    putString("errorCode", code)
    putString("errorMessage", message)
    putArray("assets", Arguments.createArray())
  }

  private fun finish(result: WritableMap) {
    val promise = pendingPromise
    pendingPromise = null
    pendingOptions = null
    pendingOriginalUri = null
    pendingCaptureFile = null
    pendingCaptureIsVideo = false
    promise?.resolve(result)
  }

  // --- small readers ------------------------------------------------------

  private fun intOr(map: ReadableMap, key: String, fallback: Int) =
    if (map.hasKey(key) && !map.isNull(key)) map.getInt(key) else fallback

  private fun doubleOr(map: ReadableMap, key: String, fallback: Double) =
    if (map.hasKey(key) && !map.isNull(key)) map.getDouble(key) else fallback

  private fun readStringArray(map: ReadableMap, key: String): List<String> {
    if (!map.hasKey(key) || map.isNull(key)) return emptyList()
    val array = map.getArray(key) ?: return emptyList()
    return (0 until array.size()).mapNotNull { array.getString(it) }
  }

  private fun parseColor(hex: String?): Int? = try {
    if (hex.isNullOrBlank()) null else Color.parseColor(hex)
  } catch (_: Exception) {
    null
  }
}
