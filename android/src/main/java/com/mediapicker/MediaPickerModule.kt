package com.mediapicker

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.CancellationSignal
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableMap
import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.modules.core.PermissionAwareActivity
import com.facebook.react.modules.core.PermissionListener
import java.io.File
import java.util.concurrent.Executors

/**
 * The JS surface. Owns the one call that can be in flight at a time and walks it
 * through gallery, camera and cropper; what each of those screens does lives in
 * [GalleryPicker], [CameraCapture] and [Cropper], and the file work in
 * [ImageProcessing] and [VideoProcessing].
 */
@ReactModule(name = MediaPickerModule.NAME)
class MediaPickerModule(private val reactContext: ReactApplicationContext) :
  NativeMediaPickerSpec(reactContext) {

  companion object {
    const val NAME = "MediaPicker"
    private const val RC_PICK = 51001
    private const val RC_CROP = 51002
    private const val RC_CAPTURE = 51003
    private const val RC_CAMERA_PERMISSION = 51004
  }

  private val gallery = GalleryPicker(reactContext)
  private val camera = CameraCapture(reactContext)
  private val cropper = Cropper(reactContext)

  private val worker = Executors.newSingleThreadExecutor()

  private var pendingPromise: Promise? = null
  private var pendingOptions: ReadableMap? = null
  private var pendingPick: GalleryPicker.Plan? = null
  private var pendingOriginalUri: String? = null
  private var pendingCaptureFile: File? = null
  private var pendingCaptureIsVideo = false

  // Set for as long as a batch of assets is being compressed, so cancelCompression
  // has something to cancel. Volatile because it is read from the worker thread
  // and written from the JS thread.
  @Volatile private var compressionCancel: CancellationSignal? = null

  private val activityListener = object : com.facebook.react.bridge.BaseActivityEventListener() {
    // `activity` is non-null in React Native 0.81+, where this listener became
    // Kotlin; it was a Java platform type before that, which accepts either.
    // Declaring it non-null is the one signature that compiles on both, and the
    // parameter is unused here anyway — `currentActivity` is what gets used.
    override fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?) {
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
      ?: return promise.resolve(Results.error("others", "No foreground activity"))
    if (pendingPromise != null) {
      return promise.resolve(Results.error("picker_busy", "A picker is already open"))
    }

    val plan = gallery.plan(activity, options)
    if (plan.limit <= 0 && options.intOr("selectionLimit", 1) > 0) {
      // Every slot is taken by preselected items the picker cannot show, so
      // there is nothing the user could add or untick.
      return promise.resolve(Results.success(Arguments.createArray()))
    }

    pendingPromise = promise
    pendingOptions = options
    pendingPick = plan
    try {
      activity.startActivityForResult(gallery.intent(activity, options, plan), RC_PICK)
    } catch (e: Exception) {
      finish(Results.error("others", e.message ?: "Could not open the picker"))
    }
  }

  override fun captureMedia(options: ReadableMap, promise: Promise) {
    val activity = currentActivity
      ?: return promise.resolve(Results.error("others", "No foreground activity"))
    if (pendingPromise != null) {
      return promise.resolve(Results.error("picker_busy", "A picker is already open"))
    }

    pendingPromise = promise
    pendingOptions = options

    if (camera.permissionMissing(activity)) {
      requestCameraPermission(activity)
    } else {
      launchCapture(activity)
    }
  }

  override fun cropImage(options: ReadableMap, promise: Promise) {
    val activity = currentActivity
      ?: return promise.resolve(Results.error("others", "No foreground activity"))
    if (pendingPromise != null) {
      return promise.resolve(Results.error("picker_busy", "A picker is already open"))
    }
    val path = options.getString("path")
    if (path.isNullOrBlank()) {
      return promise.resolve(Results.error("invalid_options", "path is required"))
    }

    pendingPromise = promise
    pendingOptions = options
    pendingOriginalUri = path
    startCrop(activity, Uri.fromFile(File(path.removePrefix("file://"))), options)
  }

  override fun compressMedia(options: ReadableMap, promise: Promise) {
    val path = options.getString("path")
    if (path.isNullOrBlank()) {
      return promise.resolve(Results.error("invalid_options", "path is required"))
    }

    // No UI, so this neither claims the picker slot nor minds that one is open.
    worker.execute {
      try {
        val file = File(path.removePrefix("file://"))
        if (!file.exists()) {
          return@execute promise.resolve(
            Results.error("cannot_process_asset", "There is no file at $path")
          )
        }
        val mime = MediaFiles.mimeForPath(file.name)
        if (!mime.startsWith("image/") && !mime.startsWith("video/")) {
          return@execute promise.resolve(
            Results.error("invalid_options", "$path is neither an image nor a video")
          )
        }

        val processed = try {
          withCancellation { compressToBudget(Processed(file, mime, file.name), options) }
        } catch (e: Exception) {
          return@execute promise.resolve(
            Results.error("compress_failed", e.message ?: "Could not compress the media")
          )
        }

        val assets = Arguments.createArray()
        assets.pushMap(Results.asset(processed, path, options, null))
        promise.resolve(Results.success(assets))
      } catch (e: Exception) {
        promise.resolve(
          Results.error("cannot_process_asset", e.message ?: "Could not read the file")
        )
      }
    }
  }

  override fun cancelCompression(promise: Promise) {
    // Safe from any thread, and safe when nothing is running.
    compressionCancel?.cancel()
    promise.resolve(null)
  }

  override fun cleanTempFiles(path: String, promise: Promise) {
    worker.execute {
      try {
        MediaFiles.deleteTemp(reactContext, path)
        promise.resolve(null)
      } catch (e: Exception) {
        promise.reject("clean_failed", e.message, e)
      }
    }
  }

  // --- picking ------------------------------------------------------------

  private fun handlePickResult(resultCode: Int, data: Intent?) {
    if (resultCode != Activity.RESULT_OK || data == null) {
      return finish(Results.cancelled())
    }

    val options = pendingOptions ?: return finish(Results.error("others", "Lost picker options"))
    val plan = pendingPick ?: GalleryPicker.Plan(options.intOr("selectionLimit", 1), emptyList())
    val selection = gallery.selection(data, options, plan) ?: return finish(Results.cancelled())

    if (selection.fresh.isEmpty()) {
      return finish(Results.success(Arguments.createArray(), selection.deselected))
    }

    worker.execute {
      try {
        val files = selection.fresh.map { uri -> gallery.copyIn(uri, options) }
        deliver(files, selection.fresh.map { it.toString() }, options, selection.deselected)
      } catch (e: Exception) {
        finish(Results.error("cannot_process_asset", e.message ?: "Could not read the selected media"))
      }
    }
  }

  // --- capture ------------------------------------------------------------

  private fun requestCameraPermission(activity: Activity) {
    val permissionAware = activity as? PermissionAwareActivity
      ?: return finish(Results.error("permission", "Activity cannot request permissions"))

    permissionAware.requestPermissions(
      arrayOf(Manifest.permission.CAMERA),
      RC_CAMERA_PERMISSION,
      PermissionListener { requestCode, _, grantResults ->
        if (requestCode == RC_CAMERA_PERMISSION) {
          val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
          if (!granted) {
            finish(Results.error("permission", "Camera permission was denied"))
          } else {
            val current = currentActivity
            if (current == null) {
              finish(Results.error("others", "No foreground activity"))
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
    val options = pendingOptions ?: return finish(Results.error("others", "Lost picker options"))
    val isVideo = options.getString("mediaType") == "video"
    val output = MediaFiles.newCacheFile(reactContext, if (isVideo) "mp4" else "jpg")

    pendingCaptureFile = output
    pendingCaptureIsVideo = isVideo

    try {
      // No <queries> entry is needed: package visibility filters resolveActivity,
      // not the ability to start an implicit intent.
      activity.startActivityForResult(camera.intent(options, isVideo, output), RC_CAPTURE)
    } catch (e: ActivityNotFoundException) {
      finish(Results.error("camera_unavailable", "No camera app is available"))
    } catch (e: Exception) {
      finish(Results.error("others", e.message ?: "Could not open the camera"))
    }
  }

  private fun handleCaptureResult(resultCode: Int, data: Intent?) {
    val output = pendingCaptureFile
    val isVideo = pendingCaptureIsVideo

    if (resultCode != Activity.RESULT_OK) {
      output?.delete()
      return finish(Results.cancelled())
    }

    val options = pendingOptions ?: return finish(Results.error("others", "Lost picker options"))

    worker.execute {
      try {
        val processed = camera.result(output, isVideo, data, options)
          ?: return@execute finish(Results.cancelled())
        deliver(listOf(processed), listOf(null), options)
      } catch (e: Exception) {
        finish(Results.error("cannot_process_asset", e.message ?: "Could not read the capture"))
      }
    }
  }

  // --- cropping -----------------------------------------------------------

  private fun startCrop(activity: Activity, source: Uri, options: ReadableMap) {
    try {
      activity.startActivityForResult(cropper.intent(activity, source, options), RC_CROP)
    } catch (e: Exception) {
      finish(Results.error("crop_failed", e.message ?: "Could not open the cropper"))
    }
  }

  private fun handleCropResult(resultCode: Int, data: Intent?) {
    if (resultCode != Activity.RESULT_OK || data == null) {
      return finish(Results.cancelled())
    }

    val options = pendingOptions ?: return finish(Results.error("others", "Lost picker options"))
    worker.execute {
      try {
        val cropped = cropper.result(resultCode, data)
        val processed = try {
          withCancellation {
            compressToBudget(Processed(cropped.file, "image/jpeg", cropped.file.name), options)
          }
        } catch (e: Exception) {
          return@execute finish(
            Results.error("compress_failed", e.message ?: "Could not compress the image")
          )
        }
        val assets = Arguments.createArray()
        assets.pushMap(Results.asset(processed, pendingOriginalUri, options, cropped.cropRect))
        finish(Results.success(assets))
      } catch (e: Exception) {
        finish(Results.error("crop_failed", e.message ?: "Cropping failed"))
      }
    }
  }

  // --- delivering ---------------------------------------------------------

  /**
   * Single exit for both picking and capturing: hand a single still image to the
   * cropper when cropping was asked for, otherwise resolve with the assets. Runs
   * on the worker thread; the cropper is dispatched back to the UI thread.
   */
  private fun deliver(
    files: List<Processed>,
    originalUris: List<String?>,
    options: ReadableMap,
    deselected: List<String> = emptyList()
  ) {
    if (options.flag("cropping") && files.size == 1 && !MediaFiles.isVideo(files[0].mime)) {
      val activity = currentActivity
        ?: return finish(Results.error("others", "No foreground activity"))
      pendingOriginalUri = originalUris.firstOrNull()
      activity.runOnUiThread {
        startCrop(activity, Uri.fromFile(files[0].file), options)
      }
      return
    }

    val compressed = try {
      withCancellation {
        files.mapIndexed { index, processed ->
          compressToBudget(processed, options, index, files.size)
        }
      }
    } catch (e: Exception) {
      return finish(Results.error("compress_failed", e.message ?: "Could not compress the media"))
    }

    val assets = Arguments.createArray()
    compressed.forEachIndexed { index, processed ->
      assets.pushMap(Results.asset(processed, originalUris.getOrNull(index), options, null))
    }
    finish(Results.success(assets, deselected))
  }

  /**
   * One signal covers a whole batch, so cancelling during a multi-select stops
   * the clip being worked on and every one still queued behind it.
   */
  private fun <T> withCancellation(block: () -> T): T {
    compressionCancel = CancellationSignal()
    try {
      return block()
    } finally {
      compressionCancel = null
    }
  }

  /**
   * The last thing that happens to an asset before it is reported: shrink it
   * under the caller's byte budget. Deliberately after processImage() and after
   * any crop, so the size it measures is the size that gets uploaded.
   */
  private fun compressToBudget(
    processed: Processed,
    options: ReadableMap,
    index: Int = 0,
    total: Int = 1
  ): Processed {
    val isVideo = MediaFiles.isVideo(processed.mime)
    val minBytes = options.longOr("minimumFileSizeForCompress")
    val cancel = compressionCancel
    val budget = options.longOr(if (isVideo) "maxVideoFileSize" else "maxImageFileSize")
    val sizeBefore = processed.file.length()

    val file = if (isVideo) {
      var lastReported = -1.0
      VideoProcessing.compressVideo(
        reactContext, processed.file, budget, minBytes, cancel
      ) { progress ->
        // The transcoder reports far more often than a UI can use, and every
        // event costs a bridge crossing, so only whole percents get through.
        if (progress - lastReported >= 0.01 || progress >= 1.0) {
          lastReported = progress
          emitProgress(progress, index, total)
        }
      }
    } else {
      ImageProcessing.compressImage(
        reactContext, processed.file, processed.mime, budget, minBytes
      )
    }

    if (file == processed.file) {
      // Unchanged and already inside its budget is the ordinary case; unchanged
      // while still over it means the work was declined, and the caller needs to
      // know which, because the file it is about to upload is too big.
      if (budget <= 0L || sizeBefore <= budget) return processed
      return processed.copy(
        compressionSkipped = when {
          cancel?.isCanceled == true -> "cancelled"
          minBytes > 0L && sizeBefore < minBytes -> "below_minimum"
          else -> null
        }
      )
    }

    // Compressing always lands on JPEG or MP4, and the reported name has to
    // follow the bytes the same way it does after a re-encode.
    return Processed(
      file,
      if (isVideo) "video/mp4" else "image/jpeg",
      MediaFiles.withExtension(processed.displayName, file.extension)
    )
  }

  private fun emitProgress(progress: Double, index: Int, total: Int) {
    emitOnCompressProgress(Arguments.createMap().apply {
      putDouble("progress", progress.coerceIn(0.0, 1.0))
      putInt("index", index)
      putInt("total", total)
    })
  }

  private fun finish(result: WritableMap) {
    val promise = pendingPromise
    pendingPromise = null
    pendingOptions = null
    pendingPick = null
    pendingOriginalUri = null
    pendingCaptureFile = null
    pendingCaptureIsVideo = false
    promise?.resolve(result)
  }
}
