package com.mediapicker

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.facebook.react.bridge.JavaOnlyMap
import com.facebook.react.bridge.PromiseImpl
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/** The guarantees that keep one call from damaging another, or files that are not ours. */
@RunWith(AndroidJUnit4::class)
class SafetyTest {

  private val context: Context = ApplicationProvider.getApplicationContext()

  @After
  fun clearCache() = MediaFiles.deleteTemp(context, "")

  private fun promise(onResolve: (Any?) -> Unit = {}) =
    PromiseImpl({ args -> onResolve(args.firstOrNull()) }, { _ -> })

  // --- the call slot ------------------------------------------------------

  @Test
  fun secondCallIsRefusedWhileOneIsOpen() {
    val pending = PendingCall()

    assertTrue(pending.claim(promise(), JavaOnlyMap()))
    assertFalse(pending.claim(promise(), JavaOnlyMap()))
  }

  @Test
  fun finishResolvesTheOpenCallAndFreesTheSlot() {
    val pending = PendingCall()
    val result = JavaOnlyMap()
    var resolved: Any? = null
    pending.claim(promise { resolved = it }, JavaOnlyMap())

    pending.finish(result)

    assertSame(result, resolved)
    assertTrue(pending.claim(promise(), JavaOnlyMap()))
  }

  @Test
  fun exactlyOneOfManySimultaneousCallsGetsTheSlot() {
    repeat(200) {
      val pending = PendingCall()
      val gate = CountDownLatch(1)
      val winners = AtomicInteger()
      val callers = (1..8).map {
        thread {
          gate.await()
          if (pending.claim(promise(), JavaOnlyMap())) winners.incrementAndGet()
        }
      }
      gate.countDown()
      callers.forEach { it.join() }
      assertEquals(1, winners.get())
    }
  }

  /**
   * The race the lock is for: a call finishing on the worker thread while the
   * next one claims the slot on the JS thread. Whichever order they land in,
   * the new call must keep the options it stored.
   */
  @Test
  fun aFinishingCallNeverClearsTheNextCallsOptions() {
    repeat(2000) {
      val pending = PendingCall()
      pending.claim(promise(), JavaOnlyMap())
      val next = JavaOnlyMap()
      val gate = CountDownLatch(1)

      val finisher = thread {
        gate.await()
        pending.finish(JavaOnlyMap())
      }
      val claimer = thread {
        gate.await()
        while (!pending.claim(promise(), next)) Thread.yield()
      }
      gate.countDown()
      finisher.join()
      claimer.join()

      assertSame(next, pending.options)
    }
  }

  // --- temp files ---------------------------------------------------------

  @Test
  fun cleaningOneTempFileDeletesIt() {
    val ours = MediaFiles.newCacheFile(context, "jpg").apply { writeText("x") }

    MediaFiles.deleteTemp(context, "file://${ours.absolutePath}")

    assertFalse(ours.exists())
  }

  @Test
  fun aPathThatClimbsOutOfTheCacheDirIsLeftAlone() {
    val victim = File(context.filesDir, "keep-me.txt").apply { writeText("x") }
    try {
      val climbing = File(MediaFiles.cacheDir(context), "../../files/keep-me.txt")

      MediaFiles.deleteTemp(context, climbing.path)

      assertTrue(victim.exists())
    } finally {
      victim.delete()
    }
  }

  @Test
  fun aSiblingDirectoryWithTheSamePrefixIsLeftAlone() {
    val sibling = File(MediaFiles.cacheDir(context).path + "2").apply { mkdirs() }
    val victim = File(sibling, "keep-me.txt").apply { writeText("x") }
    try {
      MediaFiles.deleteTemp(context, victim.path)

      assertTrue(victim.exists())
    } finally {
      sibling.deleteRecursively()
    }
  }
}
