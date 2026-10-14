package com.mediapickerexample

import android.content.ContentValues
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.ext.SdkExtensions
import android.provider.MediaStore
import androidx.test.ext.junit.rules.ActivityScenarioRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.BySelector
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import org.json.JSONObject
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.BeforeClass
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.util.regex.Pattern
import kotlin.random.Random

/**
 * Drives the example app through the real system photo picker, cropper and
 * camera, and checks the JSON it renders for each result.
 *
 * Runs against the release build, so no Metro is needed:
 *   ./gradlew :app:connectedReleaseAndroidTest
 *
 * The photos it picks are written into MediaStore before the class runs and
 * removed after, so it does not depend on what the device's gallery holds.
 */
@RunWith(AndroidJUnit4::class)
class PickerUiTest {

  companion object {
    private const val TIMEOUT = 30_000L
    private val seeded = mutableListOf<Uri>()

    /**
     * Noise rather than a flat fill: it encodes to a few MB, which is what makes
     * the size-budget cases mean something. Dated in the future so they sort to
     * the top of the picker grid.
     */
    @BeforeClass
    @JvmStatic
    fun seedPhotos() {
      val resolver = InstrumentationRegistry.getInstrumentation().targetContext.contentResolver
      val random = Random(42)
      repeat(3) { index ->
        val values = ContentValues().apply {
          put(MediaStore.Images.Media.DISPLAY_NAME, "mpk-ui-test-$index.jpg")
          put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
          put(MediaStore.Images.Media.DATE_TAKEN, System.currentTimeMillis() + 86_400_000L - index)
        }
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)!!
        val pixels = IntArray(2000 * 1500) { random.nextInt() or (0xFF shl 24) }
        val bitmap = Bitmap.createBitmap(pixels, 2000, 1500, Bitmap.Config.ARGB_8888)
        resolver.openOutputStream(uri)!!.use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }
        bitmap.recycle()
        seeded.add(uri)
      }
    }

    @AfterClass
    @JvmStatic
    fun removePhotos() {
      val resolver = InstrumentationRegistry.getInstrumentation().targetContext.contentResolver
      seeded.forEach { resolver.delete(it, null, null) }
    }
  }

  // A fresh activity per test, closed after it, so no result or held pick
  // leaks from one test into the next.
  @get:Rule
  val activity = ActivityScenarioRule(MainActivity::class.java)

  private val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())

  @Before
  fun waitForModule() {
    // The app renders this only after a native round trip came back, so the
    // TurboModule is known to be loaded before any test taps a button.
    assertNotNull(
      "module did not load",
      device.wait(Until.findObject(By.textContains("native round trip OK")), 60_000)
    )
  }

  // --- helpers ------------------------------------------------------------

  private fun tap(label: String) {
    val button = device.wait(Until.findObject(By.text(label)), TIMEOUT)
    assertNotNull("missing button: $label", button)
    button.click()
  }

  private fun waitFor(selector: BySelector, timeout: Long = TIMEOUT): UiObject2? =
    device.wait(Until.findObject(selector), timeout)

  /** The picker's grid cells, in reading order. */
  private fun pickerCells(): List<UiObject2> {
    assertNotNull("picker never opened", waitFor(By.descStartsWith("Photo taken on")))
    return device.findObjects(By.descStartsWith("Photo taken on"))
      .sortedWith(compareBy({ it.visibleBounds.top }, { it.visibleBounds.left }))
  }

  private fun pickCell(index: Int) = pickerCells()[index].click()

  private fun confirmMultiSelect() {
    val add = waitFor(By.text(Pattern.compile("(Add|Done).*")))
    assertNotNull("multi-select confirm button never appeared", add)
    add!!.click()
  }

  private fun confirmCrop() {
    val choose = waitFor(By.text(Pattern.compile("(?i)choose")))
    assertNotNull("cropper never appeared", choose)
    choose!!.click()
  }

  /**
   * The JSON the app renders for the next result. The log view keeps showing
   * the previous one until the call resolves, so wait for text that differs.
   */
  private fun nextResult(label: String, previous: String? = null): JSONObject {
    val deadline = System.currentTimeMillis() + 60_000
    while (System.currentTimeMillis() < deadline) {
      val text = device.findObject(By.textStartsWith("$label\n"))?.text
      if (text != null && text != previous && text.contains("\"didCancel\"")) {
        return JSONObject(text.substring(text.indexOf('{')))
      }
      Thread.sleep(250)
    }
    throw AssertionError("no result for $label")
  }

  private fun JSONObject.onlyAsset(): JSONObject {
    assertFalse("call failed: $this", has("errorCode"))
    val assets = getJSONArray("assets")
    assertEquals("expected exactly one asset in $this", 1, assets.length())
    return assets.getJSONObject(0)
  }

  private fun JSONObject.originalPaths(): List<String> {
    val assets = getJSONArray("assets")
    return (0 until assets.length()).map { assets.getJSONObject(it).getString("originalPath") }
  }

  private fun assertFileBacked(asset: JSONObject) {
    assertTrue("not a file uri: $asset", asset.getString("uri").startsWith("file://"))
    assertTrue("no width: $asset", asset.getInt("width") > 0)
    assertTrue("no height: $asset", asset.getInt("height") > 0)
    assertTrue("empty file: $asset", asset.getLong("fileSize") > 0)
  }

  // --- gallery ------------------------------------------------------------

  @Test
  fun pickingAPhotoReturnsAFileInTheCache() {
    tap("Photo")
    pickCell(0)

    val asset = nextResult("Photo").onlyAsset()
    assertFileBacked(asset)
    assertEquals("image/jpeg", asset.getString("type"))
    assertTrue(asset.getString("originalPath").startsWith("content://"))
  }

  @Test
  fun backingOutOfThePickerIsACancelNotAnError() {
    tap("Photo")
    pickerCells()
    device.pressBack()

    val result = nextResult("Photo")
    assertTrue("expected a cancel: $result", result.getBoolean("didCancel"))
    assertFalse(result.has("errorCode"))
    assertEquals(0, result.getJSONArray("assets").length())
  }

  @Test
  fun multiSelectKeepsTheOrderThePhotosWerePicked() {
    val identifiers = mutableListOf<String>()
    var previous: String? = null
    for (cell in 0..2) {
      tap("Photo")
      pickCell(cell)
      val result = nextResult("Photo", previous)
      previous = result.toString(2)
      identifiers += result.onlyAsset().getString("originalPath")
    }

    tap("Photos ×3")
    for (cell in listOf(2, 0, 1)) pickCell(cell)
    confirmMultiSelect()

    val result = nextResult("Photos ×3")
    assertEquals(listOf(identifiers[2], identifiers[0], identifiers[1]), result.originalPaths())
  }

  @Test
  fun extrasAddBase64ExifAndId() {
    tap("Photo +b64 +exif +extra")
    pickCell(0)

    val asset = nextResult("Photo +b64 +exif +extra").onlyAsset()
    // The app logs base64 as its length rather than the payload.
    assertTrue("no base64: $asset", asset.getString("base64").startsWith("<base64 "))
    assertNotNull("no exif: $asset", asset.optJSONObject("exif"))
    assertTrue("no id: $asset", asset.getString("id").isNotEmpty())
    assertTrue("no timestamp: $asset", asset.getString("timestamp").isNotEmpty())
  }

  @Test
  fun maxWidthAndHeightFitThePhotoInside() {
    tap("Photo max400 q0.5")
    pickCell(0)

    val asset = nextResult("Photo max400 q0.5").onlyAsset()
    assertFileBacked(asset)
    // 2000x1500 fitted inside 400x400 keeps the 4:3 ratio.
    assertEquals(400, asset.getInt("width"))
    assertEquals(300, asset.getInt("height"))
  }

  // --- cropping -----------------------------------------------------------

  @Test
  fun aPickedPhotoIsCroppedToTheRequestedSize() {
    tap("Photo + crop 1:1")
    pickCell(0)
    confirmCrop()

    val asset = nextResult("Photo + crop 1:1").onlyAsset()
    assertFileBacked(asset)
    assertEquals(1000, asset.getInt("width"))
    assertEquals(1000, asset.getInt("height"))
    assertNotNull("no cropRect: $asset", asset.optJSONObject("cropRect"))
    assertTrue("originalPath lost across the crop", asset.getString("originalPath").startsWith("content://"))
  }

  @Test
  fun backingOutOfTheCropperIsACancel() {
    tap("Photo + crop 1:1")
    pickCell(0)
    assertNotNull("cropper never appeared", waitFor(By.text(Pattern.compile("(?i)choose"))))
    device.pressBack()

    assertTrue(nextResult("Photo + crop 1:1").getBoolean("didCancel"))
  }

  // --- size budgets -------------------------------------------------------

  @Test
  fun aPickedPhotoIsBroughtUnderItsBudget() {
    tap("Photo ≤500KB")
    pickCell(0)

    val asset = nextResult("Photo ≤500KB").onlyAsset()
    assertFileBacked(asset)
    assertTrue("over budget: $asset", asset.getLong("fileSize") <= 500 * 1024)
    assertFalse(asset.has("compressionSkipped"))
  }

  @Test
  fun theDefaultFloorLeavesASmallPhotoAloneAndSaysSo() {
    tap("Photo ≤500KB (default floor)")
    pickCell(0)

    val asset = nextResult("Photo ≤500KB (default floor)").onlyAsset()
    assertTrue("fixture is under budget, so this proves nothing", asset.getLong("fileSize") > 500 * 1024)
    assertEquals("below_minimum", asset.getString("compressionSkipped"))
  }

  @Test
  fun cropThenCompressMeetsTheBudget() {
    tap("Crop then ≤200KB")
    pickCell(0)
    confirmCrop()

    val asset = nextResult("Crop then ≤200KB").onlyAsset()
    assertTrue("over budget: $asset", asset.getLong("fileSize") <= 200 * 1024)
    assertNotNull("cropRect lost to compression", asset.optJSONObject("cropRect"))
  }

  @Test
  fun compressMediaShrinksAFileAlreadyOnDisk() {
    tap("Pick → compress ≤300KB")
    pickCell(0)

    val asset = nextResult("Pick → compress ≤300KB").onlyAsset()
    assertTrue("over budget: $asset", asset.getLong("fileSize") <= 300 * 1024)
  }

  // --- preselection -------------------------------------------------------

  /**
   * Reopening with `preselected` must show the earlier picks ticked, report the
   * one unticked in `deselected`, and return only the new pick.
   */
  @Test
  fun reopeningWithPreselectedReportsWhatWasUnticked() {
    assumeTrue(
      "the photo picker gained pre-selection in SDK extension R-15",
      Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
        SdkExtensions.getExtensionVersion(Build.VERSION_CODES.R) >= 15
    )
    tap("Keep picking ×5 (0)")
    pickCell(0)
    pickCell(1)
    confirmMultiSelect()
    val first = nextResult("Keep picking: holding 0 before this pick")
    val held = first.originalPaths()
    assertEquals(2, held.size)

    tap("Keep picking ×5 (2)")
    pickCell(0) // already ticked, so this unticks it
    pickCell(2)
    confirmMultiSelect()
    val second = nextResult("Keep picking: holding 2 before this pick")

    val deselected = second.getJSONArray("deselected")
    assertEquals(1, deselected.length())
    assertEquals(held[0], deselected.getString(0))
    assertEquals(1, second.getJSONArray("assets").length())
    assertFalse("a held item came back as new", second.originalPaths().any { it in held })
  }

  // --- camera -------------------------------------------------------------

  @Test
  fun capturingMixedMediaIsRejectedWithoutOpeningTheCamera() {
    tap("Capture mixed (invalid)")

    val result = nextResult("Capture mixed (invalid)")
    assertEquals("invalid_options", result.getString("errorCode"))
  }

  /** Needs a camera app that labels its controls; the emulator's does. */
  @Test
  fun aShotFromTheCameraBecomesAJpegAsset() {
    tap("Shoot photo")
    val shutter = waitFor(By.desc("Shutter"))
    assumeTrue("no recognisable camera app on this device", shutter != null)
    shutter!!.click()
    val done = waitFor(By.desc("Done"))
    assertNotNull("camera never offered to keep the shot", done)
    done!!.click()

    val asset = nextResult("Shoot photo").onlyAsset()
    assertFileBacked(asset)
    assertEquals("image/jpeg", asset.getString("type"))
  }

  @Test
  fun backingOutOfTheCameraIsACancel() {
    tap("Shoot photo")
    assumeTrue("no recognisable camera app on this device", waitFor(By.desc("Shutter")) != null)
    device.pressBack()

    assertTrue(nextResult("Shoot photo").getBoolean("didCancel"))
  }

  // --- temp files ---------------------------------------------------------

  @Test
  fun cleaningTempFilesResolves() {
    tap("Clean temp files")
    assertNotNull(waitFor(By.text("cleanTempFiles() resolved")))
  }
}
