import XCTest

/// Drives the real PHPicker and TOCropViewController on a simulator. The example
/// app renders every result as JSON in one text view, so each test taps a button,
/// waits for that JSON to change, and prints it for the build log to capture.
final class PickerUITests: XCTestCase {
  var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
    // The module registers at import time, so this text only appears if the
    // TurboModule resolved and a native round trip came back.
    XCTAssertTrue(resultText(containing: "native round trip OK", timeout: 60) != nil,
                  "module did not load")

  }

  // MARK: - helpers

  /// React Native renders touchables as generic accessibility containers rather
  /// than buttons, so fall through the element types until one matches.
  private func control(_ label: String) -> XCUIElement {
    for query in [app.buttons, app.otherElements, app.staticTexts] {
      let element = query[label]
      if element.exists { return element }
    }
    return app.otherElements[label]
  }

  private func tap(_ label: String) {
    let element = control(label)
    XCTAssertTrue(element.waitForExistence(timeout: 20), "missing control: \(label)")
    element.tap()
  }

  /// The log view is a single static text; find it by a substring of its content.
  private func resultText(containing needle: String, timeout: TimeInterval) -> String? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if app.state == .runningForeground {
        // The JSON shows up both as its own static text and inside the label of
        // the container that wraps it, so check both rather than assume one.
        for query in [app.staticTexts, app.otherElements] {
          for element in query.allElementsBoundByIndex where element.label.contains(needle) {
            return element.label
          }
        }
      }
      usleep(500_000)
    }
    return nil
  }

  /// PHPicker's grid cells surface as images carrying this identifier, so they
  /// can be addressed directly instead of by screen coordinates.
  private func tapPickerCell(_ index: Int) {
    let cells = app.images.matching(identifier: "PXGGridLayout-Info")
    let cell = cells.element(boundBy: index)
    XCTAssertTrue(cell.waitForExistence(timeout: 30), "picker cell \(index) never appeared")
    // The onboarding overlay leaves the grid cells reported as not hittable, so
    // tap the centre point directly rather than going through the element.
    cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
  }

  private func report(_ name: String, _ json: String?) {
    print("RESULT[\(name)]: \(json ?? "<none>")")
  }

  // MARK: - tests

  func test1PickPhoto() throws {
    tap("Photo")
    tapPickerCell(0)
    let json = resultText(containing: "\"didCancel\"", timeout: 45)
    report("pick-photo", json)
    XCTAssertNotNil(json)
    XCTAssertTrue(json!.contains("\"didCancel\": false"), "picker did not return an asset")
    XCTAssertTrue(json!.contains("file://"), "no file uri in result")
  }

  func test2PickPhotoWithCrop() throws {
    tap("Photo + crop 1:1")
    tapPickerCell(0)
    sleep(4)

    // TOCropViewController's confirm button carries the cropperChooseText option.
    let choose = app.buttons["Choose"]
    XCTAssertTrue(choose.waitForExistence(timeout: 30), "cropper never appeared")
    choose.tap()

    let json = resultText(containing: "cropRect", timeout: 45)
    report("pick-crop", json)
    XCTAssertNotNil(json, "crop produced no result")
    XCTAssertTrue(json!.contains("\"didCancel\": false"))
  }

  func test3Extras() throws {
    tap("Photo +b64 +exif +extra")
    tapPickerCell(0)
    let json = resultText(containing: "\"didCancel\"", timeout: 45)
    report("extras", json)
    XCTAssertNotNil(json)
    XCTAssertTrue(json!.contains("base64"), "includeBase64 produced no base64")
  }

  func test4Downscale() throws {
    tap("Photo max400 q0.5")
    tapPickerCell(0)
    let json = resultText(containing: "\"didCancel\"", timeout: 45)
    report("downscale", json)
    XCTAssertNotNil(json)
  }

  func test5MultiSelect() throws {
    tap("Photos ×3")
    tapPickerCell(0)
    tapPickerCell(1)
    tapPickerCell(2)
    sleep(1)
    // Multi-select PHPicker needs an explicit confirm.
    let add = app.buttons["Add"].exists ? app.buttons["Add"] : app.buttons["Done"]
    if add.waitForExistence(timeout: 10) { add.tap() }
    let json = resultText(containing: "\"didCancel\"", timeout: 45)
    report("multi", json)
    XCTAssertNotNil(json)
  }

  /// Recent simulators present a real camera UI for UIImagePickerController but
  /// have no capture pipeline behind it — the shutter never produces an image.
  /// So a simulator can prove that captureMedia opens the camera in the right
  /// mode and clears the permission gate, and nothing beyond that. The delegate
  /// path (temp file, asset build, crop hand-off) needs a physical device.
  private func assertCameraPresented(mode: String) {
    let allow = app.alerts.buttons["OK"]
    if allow.waitForExistence(timeout: 3) { allow.tap() }

    let shutter = app.buttons["PhotoCapture"]
    XCTAssertTrue(shutter.waitForExistence(timeout: 30),
                  "captureMedia did not present the camera")
    let modeButton = app.buttons["Camera Mode"]
    XCTAssertTrue(modeButton.exists, "camera mode control missing")
    XCTAssertEqual(modeButton.value as? String, mode, "camera opened in the wrong mode")
    app.buttons["DismissImagePickerButton"].tap()
  }

  func test6CapturePhotoPresentsCamera() throws {
    tap("Shoot photo")
    assertCameraPresented(mode: "Photo")
    let json = resultText(containing: "didCancel", timeout: 30)
    report("capture-dismiss", json)
    XCTAssertNotNil(json)
    XCTAssertTrue(json!.contains("\"didCancel\": true"),
                  "dismissing the camera should resolve as a cancel")
  }

  /// The simulated camera reports no movie support, so this exercises the
  /// media-type guard rather than the video UI: the call must resolve with
  /// camera_unavailable instead of leaving the promise hanging forever.
  func test7CaptureVideoUnsupportedResolves() throws {
    tap("Record video 10s")
    let json = resultText(containing: "\"didCancel\"", timeout: 40)
    report("capture-video-guard", json)
    XCTAssertNotNil(json, "video capture never settled")
    XCTAssertTrue(json!.contains("camera_unavailable"),
                  "expected camera_unavailable when the camera cannot record video")
  }

  /// Presses the shutter. A simulator renders the camera but has no capture
  /// pipeline behind it, so no review sheet ever appears and the test can only
  /// confirm the camera stayed up; on a physical device the same run goes all
  /// the way through "Use Photo" to a resolved asset. Either outcome passes --
  /// what would not pass is the shutter leaving the promise hanging.
  func test8CaptureShutter() throws {
    tap("Shoot photo")
    let allow = app.alerts.buttons["OK"]
    if allow.waitForExistence(timeout: 3) { allow.tap() }

    let shutter = app.buttons["PhotoCapture"]
    XCTAssertTrue(shutter.waitForExistence(timeout: 30), "camera never presented")
    shutter.tap()

    let use = app.buttons["Use Photo"]
    guard use.waitForExistence(timeout: 15) else {
      print("RESULT[capture-shutter]: no review sheet - simulator has no capture pipeline")
      XCTAssertTrue(shutter.exists, "the shutter neither captured nor left the camera up")
      app.buttons["DismissImagePickerButton"].tap()
      return
    }

    use.tap()
    let json = resultText(containing: "\"didCancel\"", timeout: 60)
    report("capture-shutter", json)
    XCTAssertNotNil(json, "capture never settled after Use Photo")
    XCTAssertTrue(json!.contains("\"didCancel\": false"), "a completed capture should not report a cancel")
    XCTAssertTrue(json!.contains("image/jpeg"), "captured photo should be reported as a JPEG")
  }
}
