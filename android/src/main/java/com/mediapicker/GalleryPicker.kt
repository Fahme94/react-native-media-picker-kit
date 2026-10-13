package com.mediapicker

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.ext.SdkExtensions
import android.provider.OpenableColumns
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import com.facebook.react.bridge.ReadableMap

/** The system photo picker (or the document picker before it existed), and what it hands back. */
internal class GalleryPicker(private val context: Context) {

  companion object {
    // PickMultipleVisualMedia rejects unbounded requests, so "unlimited" is capped.
    private const val UNLIMITED_CAP = 100
    // MediaStore.EXTRA_PICKER_PRE_SELECTION_URIS, spelled out so compileSdk can
    // stay below 36. It reached the photo picker in SDK extension R-15, which
    // Play system updates bring to Android 11+, not only to Android 16.
    private const val EXTRA_PRE_SELECTION_URIS = "android.provider.extra.PICKER_PRE_SELECTION_URIS"
    private const val PRE_SELECTION_EXTENSION_VERSION = 15
  }

  /**
   * How a pick was opened. [shown] is the part of `preselected` the picker was
   * told to tick, and the only part that can be reported as deselected. [limit]
   * is the selectionLimit handed to the picker, already lowered by the
   * preselected items it could not show.
   */
  class Plan(val limit: Int, val shown: List<String>)

  /** What the user ended up with: new items to import, and shown items they unticked. */
  class Selection(val fresh: List<Uri>, val deselected: List<String>)

  fun plan(activity: Activity, options: ReadableMap): Plan {
    val requested = options.intOr("selectionLimit", 1)
    val preselected = options.stringList("preselected")
    fun lowered(hidden: Int) = if (requested <= 0) requested else requested - hidden

    if (preselected.isNotEmpty() && supportsPreSelection(activity)) {
      // An item whose read grant is gone cannot be ticked, so it must not be
      // reported as unticked either; it just keeps its slot.
      val shown = preselected.filter { isReadable(Uri.parse(it)) }
      val limit = lowered(preselected.size - shown.size)
      // Pre-selection is multi-select only.
      if (limit != 1) return Plan(limit, shown)
    }
    return Plan(lowered(preselected.size), emptyList())
  }

  private fun supportsPreSelection(activity: Activity): Boolean =
    Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
      SdkExtensions.getExtensionVersion(Build.VERSION_CODES.R) >= PRE_SELECTION_EXTENSION_VERSION &&
      ActivityResultContracts.PickVisualMedia.isPhotoPickerAvailable(activity)

  private fun isReadable(uri: Uri): Boolean = try {
    context.contentResolver
      .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
      ?.use { it.moveToFirst() } ?: false
  } catch (_: Exception) {
    false
  }

  fun intent(activity: Activity, options: ReadableMap, plan: Plan): Intent {
    val mediaType = options.getString("mediaType") ?: "photo"
    val limit = plan.limit

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
        ActivityResultContracts.PickMultipleVisualMedia(max).createIntent(activity, request).apply {
          if (plan.shown.isNotEmpty()) {
            putParcelableArrayListExtra(
              EXTRA_PRE_SELECTION_URIS,
              ArrayList(plan.shown.map { Uri.parse(it) })
            )
          }
        }
      }
    }

    // Pre-photo-picker devices: Storage Access Framework. Still no permission needed.
    val mimes = options.stringList("restrictMimeTypes").ifEmpty {
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

  /** Null when the result can only be read as a cancel. */
  fun selection(data: Intent, options: ReadableMap, plan: Plan): Selection? {
    val uris = mutableListOf<Uri>()
    data.clipData?.let { clip ->
      for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
    } ?: data.data?.let { uris.add(it) }

    // With nothing shown ticked, an empty result can only be a cancel. When
    // items were shown, it means the user unticked all of them.
    if (uris.isEmpty() && plan.shown.isEmpty()) return null

    // The picker hands back preselected items alongside new ones, and where it
    // could not show them a re-pick is a duplicate; the caller holds both.
    val preselected = options.stringList("preselected").toSet()
    val picked = uris.map { it.toString() }.toSet()
    val deselected = plan.shown.filterNot { it in picked }
    val fresh = uris.filterNot { it.toString() in preselected }
      // The document picker fallback has no limit of its own.
      .let { if (plan.limit > 0) it.take(plan.limit) else it }
    return Selection(fresh, deselected)
  }

  /** Copy one pick out of the picker's grant and into a file this module owns. */
  fun copyIn(uri: Uri, options: ReadableMap): Processed {
    val mime = MediaFiles.mimeType(context, uri)
    val forceJpg = options.flag("forceJpg", true)
    val extension = MediaFiles.extensionFor(mime, forceJpg)
    val name = MediaFiles.displayName(context, uri, "media.$extension")

    var file = MediaFiles.copyToCache(context, uri, extension)

    if (!MediaFiles.isVideo(mime)) {
      file = ImageProcessing.processImage(
        context = context,
        source = file,
        mime = mime,
        maxWidth = options.intOr("maxWidth", 0),
        maxHeight = options.intOr("maxHeight", 0),
        quality = options.doubleOr("quality", 1.0),
        forceJpg = forceJpg
      )
    }

    val finalMime = if (!MediaFiles.isVideo(mime) && forceJpg && mime != "image/gif") "image/jpeg" else mime
    // The gallery's display name still carries the source extension, so a
    // re-encoded PNG would be reported as "shot.png" while both the file on
    // disk and `type` say JPEG. Report the extension the bytes actually have.
    return Processed(file, finalMime, MediaFiles.withExtension(name, file.extension))
  }
}
