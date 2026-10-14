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

  /// Recording the docs GIFs sets UI_TEST_HOLD (seconds) so the result stays on
  /// screen long enough to see; xcodebuild passes it on from
  /// TEST_RUNNER_UI_TEST_HOLD. Ordinary runs leave it unset.
  override func tearDownWithError() throws {
    if let hold = ProcessInfo.processInfo.environment["UI_TEST_HOLD"].flatMap(UInt32.init) {
      sleep(hold)
    }
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
        // Matched by predicate rather than walked by index: React Native
        // re-renders while this polls, and an index taken a moment earlier can
        // point past the end of the list by the time it is read.
        for query in [app.staticTexts, app.otherElements] {
          let match = query.matching(NSPredicate(format: "label CONTAINS %@", needle)).firstMatch
          if match.exists { return match.label }
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

  /// The budget is checked on the bytes that reach JS, after the pick.
  func test10PickUnderABudget() throws {
    tap("Photo ≤500KB")
    tapPickerCell(0)
    let json = nextResult(after: nil, containing: "fileSize")
    report("budget", json)
    guard let asset = (resultObject(in: json)?["assets"] as? [[String: Any]])?.first,
          let size = asset["fileSize"] as? Int
    else { return XCTFail("no asset in \(json ?? "<none>")") }
    XCTAssertLessThanOrEqual(size, 500 * 1024, "over budget")
  }

  /// cropImage called on its own, on a file already on disk. It runs on the
  /// module's queue rather than after a pick, so this is the path that has to
  /// hop to main itself before presenting the cropper.
  func test11CropImageOnAFileOnDisk() throws {
    tap("Pick → cropImage 300×300")
    tapPickerCell(0)

    let choose = app.buttons["Choose"]
    XCTAssertTrue(choose.waitForExistence(timeout: 30), "cropper never appeared")
    choose.tap()

    let json = nextResult(after: nil, containing: "cropRect")
    report("crop-image", json)
    guard let asset = (resultObject(in: json)?["assets"] as? [[String: Any]])?.first
    else { return XCTFail("no asset in \(json ?? "<none>")") }
    XCTAssertEqual(asset["width"] as? Int, 300)
    XCTAssertEqual(asset["height"] as? Int, 300)
    XCTAssertTrue((asset["originalPath"] as? String)?.hasPrefix("file://") == true,
                  "originalPath should be the path that was cropped")
  }

  /// PHPicker loads a multi-selection concurrently, so this proves the assets
  /// still come back in the order the user tapped them. Each cell's identifier is
  /// learned from a single pick first, then the three are multi-picked out of
  /// grid order.
  func test5bMultiSelectKeepsPickOrder() throws {
    var identifiers: [String] = []
    var previous: String? = nil
    for cell in 0..<3 {
      tap("Photo")
      tapPickerCell(cell)
      previous = nextResult(after: previous, containing: "originalPath")
      let paths = originalPaths(in: previous)
      XCTAssertEqual(paths.count, 1, "single pick of cell \(cell) returned \(paths)")
      identifiers += paths
    }

    tap("Photos ×3")
    for cell in [2, 0, 1] { tapPickerCell(cell) }
    confirmMultiSelect()
    let json = nextResult(after: previous, containing: "\"assets\"")
    report("multi-order", json)

    XCTAssertEqual(originalPaths(in: json),
                   [identifiers[2], identifiers[0], identifiers[1]],
                   "assets did not come back in the order they were picked")
  }

  /// The result view only changes when a call resolves, so wait for text that
  /// differs from the last result rather than for any result at all.
  private func nextResult(after previous: String?, containing needle: String) -> String? {
    let deadline = Date().addingTimeInterval(45)
    while Date() < deadline {
      if let text = resultText(containing: needle, timeout: 1), text != previous {
        return text
      }
    }
    return nil
  }

  /// The result JSON inside a matched label. When the match is the container
  /// rather than the log text, its label also carries every button label before
  /// the JSON and the scroll bars' descriptions after it, so cut from the first
  /// brace to the last.
  private func resultObject(in text: String?) -> [String: Any]? {
    guard let text, let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
          start < end
    else { return nil }
    return try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
  }

  private func originalPaths(in text: String?) -> [String] {
    guard let assets = resultObject(in: text)?["assets"] as? [[String: Any]] else { return [] }
    return assets.compactMap { $0["originalPath"] as? String }
  }

  private func confirmMultiSelect() {
    sleep(1)
    let add = app.buttons["Add"].exists ? app.buttons["Add"] : app.buttons["Done"]
    if add.waitForExistence(timeout: 10) { add.tap() }
  }

  /// Reopening with `preselected` must show the earlier picks ticked, return only
  /// the new pick, and report the unticked one in `deselected`.
  func test9PreselectedRoundTrip() throws {
    tap("Keep picking ×5 (0)")
    tapPickerCell(0)
    tapPickerCell(1)
    confirmMultiSelect()
    let first = resultText(containing: "holding 0 before", timeout: 45)
    report("preselect-first", first)
    XCTAssertNotNil(first)
    XCTAssertTrue(first!.contains("\"deselected\": []"), "a pick without preselected reported deselected items")

    // Cell 0 opens ticked, so tapping it unticks; cell 2 is new.
    tap("Keep picking ×5 (2)")
    tapPickerCell(0)
    tapPickerCell(2)
    confirmMultiSelect()
    let second = resultText(containing: "holding 2 before", timeout: 45)
    report("preselect-second", second)
    XCTAssertNotNil(second)
    let result = try XCTUnwrap(resultObject(in: second), "no result JSON in \(second ?? "<none>")")
    XCTAssertEqual((result["assets"] as? [Any])?.count, 1, "only the new pick should come back")
    XCTAssertEqual((result["deselected"] as? [Any])?.count, 1, "the unticked pick should be deselected")
    XCTAssertTrue(control("Keep picking ×5 (2)").waitForExistence(timeout: 10),
                  "the app should hold two photos after swapping one")
  }

  /// Recent simulators present a real camera UI for UIImagePickerController but
  /// have no capture pipeline behind it — the shutter never produces an image.
  /// So a simulator can prove that captureMedia opens the camera in the right
  /// mode and clears the permission gate, and nothing beyond that. The delegate
  /// path (temp file, asset build, crop hand-off) needs a physical device.
  private func assertCameraPresented(mode: String) throws {
    try waitForCamera()
    // Older camera UIs show a mode switcher; newer ones drop it when only one
    // mode is allowed, and the PhotoCapture shutter already says which one.
    let modeButton = app.buttons["Camera Mode"]
    if modeButton.exists {
      XCTAssertEqual(modeButton.value as? String, mode, "camera opened in the wrong mode")
    }
    dismissCamera()
  }

  /// Older camera UIs give the close control an identifier; newer ones show a
  /// plain Cancel button.
  private func dismissCamera() {
    let dismiss = app.buttons["DismissImagePickerButton"]
    (dismiss.exists ? dismiss : app.buttons["Cancel"]).tap()
  }

  /// Clears the permission prompt and waits for the shutter. A simulator on a
  /// host with no camera at all (a CI runner) reports the camera source as
  /// unavailable, and captureMedia rightly resolves camera_unavailable instead,
  /// so there is nothing to drive: skip, as the Android tests do.
  @discardableResult
  private func waitForCamera() throws -> XCUIElement {
    let allow = app.alerts.buttons["OK"]
    if allow.waitForExistence(timeout: 3) { allow.tap() }

    let shutter = app.buttons["PhotoCapture"]
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
      if shutter.exists { return shutter }
      if resultText(containing: "camera_unavailable", timeout: 1) != nil {
        throw XCTSkip("this simulator has no camera")
      }
    }
    XCTFail("captureMedia did not present the camera")
    return shutter
  }

  func test6CapturePhotoPresentsCamera() throws {
    tap("Shoot photo")
    try assertCameraPresented(mode: "Photo")
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
    let shutter = try waitForCamera()
    shutter.tap()

    let use = app.buttons["Use Photo"]
    guard use.waitForExistence(timeout: 15) else {
      print("RESULT[capture-shutter]: no review sheet - simulator has no capture pipeline")
      XCTAssertTrue(shutter.exists, "the shutter neither captured nor left the camera up")
      dismissCamera()
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
