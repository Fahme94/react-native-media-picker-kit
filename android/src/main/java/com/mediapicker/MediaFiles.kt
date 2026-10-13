package com.mediapicker

import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Base64
import android.webkit.MimeTypeMap
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

/** The module's cache directory, and what it needs to know about files in general. */
object MediaFiles {

  private const val CACHE_DIR = "rn_media_picker"

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

  fun base64(file: File): String = Base64.encodeToString(file.readBytes(), Base64.NO_WRAP)

  /**
   * Replacing a file means dropping the one it replaced — but compressMedia()
   * takes any path the caller hands it, so only this module's own cache files
   * are ever removed.
   */
  internal fun deleteIfOurs(context: Context, file: File) {
    if (isInCacheDir(context, file)) file.delete()
  }

  fun deleteTemp(context: Context, path: String) {
    val dir = cacheDir(context)
    if (path.isBlank()) {
      dir.listFiles()?.forEach { it.delete() }
      return
    }
    val file = File(path.removePrefix("file://"))
    // Only ever delete inside our own cache dir.
    if (isInCacheDir(context, file)) file.delete()
  }

  /**
   * Resolved before comparing, so neither `rn_media_picker/../../files/x` nor a
   * sibling such as `rn_media_picker2/x` passes for a file of ours.
   */
  private fun isInCacheDir(context: Context, file: File): Boolean =
    file.canonicalPath.startsWith(cacheDir(context).canonicalPath + File.separator)
}
