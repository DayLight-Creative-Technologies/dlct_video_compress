package com.example.video_compress

import android.content.Context
import android.content.ContextWrapper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.Callable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

/**
 * A compress is answered exactly once ([VideoCompressPlugin.PendingCompress]),
 * although the `cancelCompression` handler and the transcoder's own callback
 * can both try to answer it. Each test makes a second answer attempt, the way
 * the transcoder's late callback does, so each fails if the guard is removed.
 *
 * The cancel tests run the plugin's real `cancelCompression` handler on a
 * plugin holding the compress as its running one.
 */
class PendingCompressTest {

    /** Records every answer a [MethodChannel.Result] receives. */
    private class RecordingResult : MethodChannel.Result {
        val answers = mutableListOf<String>()
        var successValue: Any? = null
        var errorCode: String? = null

        override fun success(result: Any?) {
            answers.add("success")
            successValue = result
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            answers.add("error")
            this.errorCode = errorCode
        }

        override fun notImplemented() {
            answers.add("notImplemented")
        }
    }

    private class NoOpMessenger : BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
    }

    /** What the transcoder's onTranscodeCanceled answers, arriving late. */
    private val lateCancelledAnswer: (MethodChannel.Result) -> Unit =
        { it.success("""{"isCancel":true}""") }

    private lateinit var tempDir: File
    private lateinit var plugin: VideoCompressPlugin

    @Before
    fun setUp() {
        tempDir = File(System.getProperty("java.io.tmpdir"), "pending_compress_" + System.nanoTime())
        assertTrue(tempDir.mkdirs())
        plugin = VideoCompressPlugin()
        // The plugin ignores every call until it holds a context and a channel.
        val init = VideoCompressPlugin::class.java.getDeclaredMethod(
            "init", Context::class.java, BinaryMessenger::class.java)
        init.isAccessible = true
        init.invoke(plugin, ContextWrapper(null), NoOpMessenger())
    }

    @After
    fun tearDown() {
        tempDir.deleteRecursively()
    }

    private fun destPath(): String = File(tempDir, "VID_out.mp4").path

    private fun setRunning(compress: VideoCompressPlugin.PendingCompress?) {
        val field = VideoCompressPlugin::class.java.getDeclaredField("pending")
        field.isAccessible = true
        field.set(plugin, compress)
    }

    private fun running(): Any? {
        val field = VideoCompressPlugin::class.java.getDeclaredField("pending")
        field.isAccessible = true
        return field.get(plugin)
    }

    private fun cancelCompression(): RecordingResult {
        val cancelResult = RecordingResult()
        plugin.onMethodCall(MethodCall("cancelCompression", null), cancelResult)
        return cancelResult
    }

    private fun assertAnsweredCancelledWithoutPath(result: RecordingResult) {
        assertEquals(listOf("success"), result.answers)
        val json = JSONObject(result.successValue as String)
        assertTrue(json.getBoolean("isCancel"))
        assertFalse(json.has("path"))
    }

    @Test
    fun completedCompressIsAnsweredExactlyOnce() {
        val result = RecordingResult()
        val compress = VideoCompressPlugin.PendingCompress(destPath(), result)

        compress.answer { it.success("""{"path":"out.mp4","isCancel":false}""") }
        // A failure reported for the same compress afterwards.
        compress.answer { it.error("video_compress", "compressVideo error", "late") }

        assertEquals(listOf("success"), result.answers)
        assertEquals("""{"path":"out.mp4","isCancel":false}""", result.successValue)
        assertNull(result.errorCode)
        assertTrue(compress.answered)
    }

    @Test
    fun cancelBeforeTranscodeStartsAnswersCancelledOnceWithoutPath() {
        val result = RecordingResult()
        val compress = VideoCompressPlugin.PendingCompress(destPath(), result)
        // The worker never ran: no listener callback will ever answer.
        compress.future = FutureTask(Callable<Void> { null })
        setRunning(compress)

        val cancelResult = cancelCompression()

        assertAnsweredCancelledWithoutPath(result)
        assertEquals(listOf("success"), cancelResult.answers)
        assertEquals(false, cancelResult.successValue)
        assertNull(running())
        assertTrue(compress.future!!.isCancelled)

        compress.answer(lateCancelledAnswer)

        assertEquals(listOf("success"), result.answers)
    }

    @Test
    fun cancelDuringTranscodeAnswersOnceAndDeletesPartialOutput() {
        val result = RecordingResult()
        val dest = destPath()
        val compress = VideoCompressPlugin.PendingCompress(dest, result)
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val transcode = FutureTask(Callable<Void> {
            File(dest).writeBytes(ByteArray(4096) { 1 })
            started.countDown()
            release.await()
            null
        })
        compress.future = transcode
        setRunning(compress)
        val worker = Thread(transcode)
        worker.start()
        try {
            assertTrue(started.await(5, TimeUnit.SECONDS))
            assertTrue(File(dest).exists())

            cancelCompression()

            assertAnsweredCancelledWithoutPath(result)
            assertFalse(File(dest).exists())
            assertNull(running())

            // The transcoder notices the cancel and answers again.
            compress.answer(lateCancelledAnswer)

            assertEquals(listOf("success"), result.answers)
        } finally {
            release.countDown()
            worker.join(5000)
        }
    }

    @Test
    fun failedCompressAnswersErrorOnce() {
        val result = RecordingResult()
        val compress = VideoCompressPlugin.PendingCompress(destPath(), result)

        compress.answer { it.error("video_compress", "compressVideo error", "codec") }
        // A cancel answered for the same compress afterwards.
        compress.answer(lateCancelledAnswer)

        assertEquals(listOf("error"), result.answers)
        assertEquals("video_compress", result.errorCode)
        assertNull(result.successValue)
    }

    @Test
    fun answerAfterTheFirstIsIgnored() {
        val result = RecordingResult()
        val compress = VideoCompressPlugin.PendingCompress(destPath(), result)
        assertFalse(compress.answered)

        compress.answer { it.success("first") }
        var laterReplyRan = false
        compress.answer {
            laterReplyRan = true
            it.success("second")
        }
        compress.answer { it.notImplemented() }

        assertFalse(laterReplyRan)
        assertEquals(listOf("success"), result.answers)
        assertEquals("first", result.successValue)
        assertTrue(compress.answered)
    }
}
