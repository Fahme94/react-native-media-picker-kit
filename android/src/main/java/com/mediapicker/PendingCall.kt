package com.mediapicker

import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableMap
import java.io.File

/**
 * The one picker, camera or cropper call that can be open at a time, and what
 * it carries between its activity hops.
 *
 * A call is claimed on the JS thread and finished on whichever thread its last
 * step ran on, so claiming and finishing share a lock. Without it a finish on
 * the worker clearing its fields could interleave with the next call's claim,
 * and that call would lose the options it had just stored.
 */
internal class PendingCall {

  private var promise: Promise? = null
  var options: ReadableMap? = null
    private set
  var pick: GalleryPicker.Plan? = null
  var originalUri: String? = null
  var captureFile: File? = null
  var captureIsVideo = false

  /** False when another call already holds the slot. */
  @Synchronized
  fun claim(promise: Promise, options: ReadableMap): Boolean {
    if (this.promise != null) return false
    this.promise = promise
    this.options = options
    return true
  }

  /** Resolves the open call, if there is one, and frees the slot for the next. */
  fun finish(result: WritableMap) {
    val promise = synchronized(this) {
      val held = promise
      promise = null
      options = null
      pick = null
      originalUri = null
      captureFile = null
      captureIsVideo = false
      held
    }
    // Outside the lock: resolving hands control to React, which has no business
    // holding up the next claim.
    promise?.resolve(result)
  }
}
