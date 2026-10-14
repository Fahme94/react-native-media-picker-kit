package com.mediapicker

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.net.Uri
import android.provider.MediaStore
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.facebook.react.bridge.JavaOnlyArray
import com.facebook.react.bridge.JavaOnlyMap
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.FileOutputStream

/**
 * The decisions each flow makes between a system screen handing back its result
 * and the asset reaching JS: which picks are new, which file the camera really
 * wrote, how an image is resized or re-encoded, and what it is called after.
 */
@RunWith(AndroidJUnit4::class)
class FlowLogicTest {

  private val context: Context = ApplicationProvider.getApplicationContext()

  @After
  fun clearCache() = MediaFiles.deleteTemp(context, "")

  private fun options(vararg pairs: Pair<String, Any?>) = JavaOnlyMap().apply {
    for ((key, value) in pairs) {
      when (value) {
        is Boolean -> putBoolean(key, value)
        is Int -> putInt(key, value)
        is Double -> putDouble(key, value)
        is String -> putString(key, value)
        is List<*> -> putArray(key, JavaOnlyArray.from(value))
        null -> putNull(key)
      }
    }
  }

  private fun pickResult(vararg uris: String): Intent = Intent().apply {
    if (uris.isEmpty()) return@apply
    val clip = ClipData.newRawUri("", Uri.parse(uris[0]))
    uris.drop(1).forEach { clip.addItem(ClipData.Item(Uri.parse(it))) }
    clipData = clip
  }

  private fun writeImage(
    width: Int,
    height: Int,
    format: Bitmap.CompressFormat,
    extension: String
  ): File {
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    bitmap.eraseColor(Color.rgb(200, 60, 40))
    val file = MediaFiles.newCacheFile(context, extension)
    FileOutputStream(file).use { bitmap.compress(format, 100, it) }
    bitmap.recycle()
    return file
  }

  // --- gallery: what the picker handed back -------------------------------

  @Test
  fun anEmptyResultWithNothingShownTickedIsACancel() {
    val plan = GalleryPicker.Plan(1, emptyList())

    assertNull(GalleryPicker(context).selection(pickResult(), options(), plan))
  }

  @Test
  fun anEmptyResultAfterShowingTicksMeansEverythingWasUnticked() {
    val plan = GalleryPicker.Plan(5, listOf("content://a", "content://b"))
    val opts = options("preselected" to listOf("content://a", "content://b"))

    val selection = GalleryPicker(context).selection(pickResult(), opts, plan)!!

    assertEquals(emptyList<Uri>(), selection.fresh)
    assertEquals(listOf("content://a", "content://b"), selection.deselected)
  }

  @Test
  fun preselectedItemsAreNotReturnedAgainAndUntickedOnesAreReported() {
    val plan = GalleryPicker.Plan(5, listOf("content://a", "content://b"))
    val opts = options("preselected" to listOf("content://a", "content://b"))

    val selection = GalleryPicker(context)
      .selection(pickResult("content://b", "content://c"), opts, plan)!!

    assertEquals(listOf(Uri.parse("content://c")), selection.fresh)
    assertEquals(listOf("content://a"), selection.deselected)
  }

  /** Items the picker could not show were never ticked, so they cannot be unticked. */
  @Test
  fun aPreselectedItemThePickerCouldNotShowIsNeverReportedDeselected() {
    val plan = GalleryPicker.Plan(4, listOf("content://a"))
    val opts = options("preselected" to listOf("content://a", "content://gone"))

    val selection = GalleryPicker(context).selection(pickResult("content://a"), opts, plan)!!

    assertEquals(emptyList<String>(), selection.deselected)
  }

  @Test
  fun picksComeBackInTheOrderThePickerReturnedThem() {
    val plan = GalleryPicker.Plan(0, emptyList())

    val selection = GalleryPicker(context)
      .selection(pickResult("content://3", "content://1", "content://2"), options(), plan)!!

    assertEquals(listOf("content://3", "content://1", "content://2"), selection.fresh.map { it.toString() })
  }

  /** The document picker fallback has no limit of its own, so the plan's is applied. */
  @Test
  fun picksBeyondTheLimitAreDropped() {
    val plan = GalleryPicker.Plan(2, emptyList())

    val selection = GalleryPicker(context)
      .selection(pickResult("content://1", "content://2", "content://3"), options(), plan)!!

    assertEquals(2, selection.fresh.size)
  }

  // --- camera: which file the camera really wrote -------------------------

  @Test
  fun theOutputFileWinsWhenTheCameraWroteToIt() {
    val output = writeImage(640, 480, Bitmap.CompressFormat.JPEG, "jpg")
    // Camera apps echo EXTRA_OUTPUT back; that must not be read as "ignored it".
    val echoed = Intent().setData(Uri.fromFile(output))

    val processed = CameraCapture(context).result(output, false, echoed, options())!!

    assertSame(output, processed.file)
    assertTrue(output.exists())
    assertEquals("image/jpeg", processed.mime)
  }

  @Test
  fun mediaKeptElsewhereIsCopiedIntoTheCache() {
    val output = MediaFiles.newCacheFile(context, "jpg") // never written
    val elsewhere = File(context.filesDir, "camera-kept.jpg")
    writeImage(640, 480, Bitmap.CompressFormat.JPEG, "jpg").copyTo(elsewhere, overwrite = true)
    try {
      val processed = CameraCapture(context)
        .result(output, false, Intent().setData(Uri.fromFile(elsewhere)), options())!!

      assertTrue(processed.file.path.startsWith(MediaFiles.cacheDir(context).path))
      assertTrue(processed.file.length() > 0)
      assertEquals("image/jpeg", processed.mime)
    } finally {
      elsewhere.delete()
    }
  }

  @Test
  fun okWithNothingWrittenIsACancelAndLeavesNoFileBehind() {
    val output = MediaFiles.newCacheFile(context, "jpg").apply { createNewFile() }

    assertNull(CameraCapture(context).result(output, false, null, options()))
    assertFalse(output.exists())
  }

  @Test
  fun aRecordingIsReportedAsItIs() {
    val output = MediaFiles.newCacheFile(context, "mp4").apply { writeBytes(ByteArray(1024) { 1 }) }

    val processed = CameraCapture(context).result(output, true, null, options("maxWidth" to 10))!!

    assertSame(output, processed.file)
    assertEquals("video/mp4", processed.mime)
  }

  @Test
  fun aShotGoesThroughMaxWidthLikeAGalleryPick() {
    val output = writeImage(1200, 900, Bitmap.CompressFormat.JPEG, "jpg")

    val processed = CameraCapture(context)
      .result(output, false, null, options("maxWidth" to 400, "maxHeight" to 400))!!

    assertEquals(400 to 300, ImageProcessing.imageDimensions(processed.file))
  }

  // --- camera: what the camera app is asked for ---------------------------

  @Test
  fun aVideoCaptureCarriesItsDurationLimitAndQuality() {
    val output = MediaFiles.newCacheFile(context, "mp4")

    val intent = CameraCapture(context)
      .intent(options("durationLimit" to 10, "videoQuality" to "low"), true, output)

    assertEquals(MediaStore.ACTION_VIDEO_CAPTURE, intent.action)
    assertEquals(10, intent.getIntExtra(MediaStore.EXTRA_DURATION_LIMIT, -1))
    assertEquals(0, intent.getIntExtra(MediaStore.EXTRA_VIDEO_QUALITY, -1))
    assertNotNull("no output uri for the camera to write to", intent.extras?.get(MediaStore.EXTRA_OUTPUT))
  }

  @Test
  fun aPhotoCaptureSetsNoVideoExtras() {
    val intent = CameraCapture(context)
      .intent(options("durationLimit" to 10), false, MediaFiles.newCacheFile(context, "jpg"))

    assertEquals(MediaStore.ACTION_IMAGE_CAPTURE, intent.action)
    assertFalse(intent.hasExtra(MediaStore.EXTRA_DURATION_LIMIT))
    assertFalse(intent.hasExtra(MediaStore.EXTRA_VIDEO_QUALITY))
  }

  @Test
  fun theFrontCameraIsAskedForWithTheHintsCameraAppsRead() {
    val intent = CameraCapture(context)
      .intent(options("cameraType" to "front"), false, MediaFiles.newCacheFile(context, "jpg"))

    assertEquals(1, intent.getIntExtra("android.intent.extras.CAMERA_FACING", -1))
    assertTrue(intent.getBooleanExtra("android.intent.extra.USE_FRONT_CAMERA", false))
  }

  // --- image processing ---------------------------------------------------

  @Test
  fun aPngIsReencodedAsJpegByDefault() {
    val png = writeImage(300, 200, Bitmap.CompressFormat.PNG, "png")

    val out = ImageProcessing.processImage(context, png, "image/png", 0, 0, 1.0, forceJpg = true)

    assertEquals("jpg", out.extension)
    assertEquals("image/jpeg", BitmapFactory.Options().also {
      it.inJustDecodeBounds = true
      BitmapFactory.decodeFile(out.path, it)
    }.outMimeType)
    assertFalse("the replaced PNG was left behind", png.exists())
  }

  @Test
  fun aPngIsLeftAloneWhenForceJpgIsOff() {
    val png = writeImage(300, 200, Bitmap.CompressFormat.PNG, "png")

    val out = ImageProcessing.processImage(context, png, "image/png", 0, 0, 1.0, forceJpg = false)

    assertSame(png, out)
  }

  @Test
  fun aGifIsNeverReencodedBecauseThatWouldDropItsAnimation() {
    val gif = MediaFiles.newCacheFile(context, "gif").apply { writeBytes(ByteArray(64)) }

    val out = ImageProcessing.processImage(context, gif, "image/gif", 10, 10, 0.5, forceJpg = true)

    assertSame(gif, out)
  }

  @Test
  fun qualityBelowOneReencodesAJpeg() {
    val jpeg = writeImage(800, 600, Bitmap.CompressFormat.JPEG, "jpg")

    val out = ImageProcessing.processImage(context, jpeg, "image/jpeg", 0, 0, 0.3, forceJpg = true)

    assertNotEquals(jpeg, out)
    assertEquals(800 to 600, ImageProcessing.imageDimensions(out))
  }

  @Test
  fun anImageSmallerThanMaxWidthIsNeverEnlarged() {
    val jpeg = writeImage(300, 200, Bitmap.CompressFormat.JPEG, "jpg")

    val out = ImageProcessing.processImage(context, jpeg, "image/jpeg", 1000, 1000, 0.9, forceJpg = true)

    assertEquals(300 to 200, ImageProcessing.imageDimensions(out))
  }

  // --- names and types ----------------------------------------------------

  @Test
  fun aReportedNameFollowsTheExtensionOfTheBytes() {
    assertEquals("shot.jpg", MediaFiles.withExtension("shot.png", "jpg"))
    assertEquals("shot.jpg", MediaFiles.withExtension("shot", "jpg"))
    assertEquals("shot.png", MediaFiles.withExtension("shot.png", ""))
  }

  @Test
  fun theCacheExtensionMatchesWhatWillBeWritten() {
    assertEquals("jpg", MediaFiles.extensionFor("image/png", forceJpg = true))
    assertEquals("png", MediaFiles.extensionFor("image/png", forceJpg = false))
    assertEquals("gif", MediaFiles.extensionFor("image/gif", forceJpg = false))
    assertEquals("mp4", MediaFiles.extensionFor("video/mp4", forceJpg = true))
    // The real extensions, not the MIME subtype: a .mov must not be reported as
    // "IMG_0001.quicktime" to a backend that checks extensions.
    assertEquals("mov", MediaFiles.extensionFor("video/quicktime", forceJpg = true))
  }

  @Test
  fun aPathIsTypedByItsExtension() {
    assertEquals("image/jpeg", MediaFiles.mimeForPath("a.JPG"))
    assertEquals("video/mp4", MediaFiles.mimeForPath("clip.mp4"))
    assertEquals("application/octet-stream", MediaFiles.mimeForPath("notes"))
    assertNotNull(MediaFiles.mimeForPath("x.heic"))
  }
}
