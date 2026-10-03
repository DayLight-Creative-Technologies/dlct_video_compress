package com.example.video_compress

import android.content.Context
import android.content.ContextWrapper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer

/**
 * The `getMediaInfo` and `deleteAllCache` channel calls, through the plugin's
 * public API only, each answered exactly once. `getMediaInfo` runs on a file
 * that lacks duration, width and height metadata: the android.jar stub's
 * MediaMetadataRetriever reports no metadata at all (every extractMetadata
 * is null), which is exactly that file.
 */
class MediaInfoTest {

    private class RecordingResult : MethodChannel.Result {
        val answers = mutableListOf<String>()
        var successValue: Any? = null

        override fun success(result: Any?) {
            answers.add("success")
            successValue = result
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            answers.add("error")
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

    private lateinit var tempDir: File
    private lateinit var video: File

    @Before
    fun setUp() {
        tempDir = File(System.getProperty("java.io.tmpdir"), "media_info_" + System.nanoTime())
        check(tempDir.mkdirs())
        video = File(tempDir, "no_metadata.mp4")
        video.writeBytes(ByteArray(1234))
    }

    @After
    fun tearDown() {
        tempDir.deleteRecursively()
    }

    private fun assertNoMetadataJson(json: JSONObject) {
        assertEquals(setOf("path", "title", "author", "filesize"), json.keys().asSequence().toSet())
        assertEquals(video.path, json.getString("path"))
        assertEquals("", json.getString("title"))
        assertEquals("", json.getString("author"))
        assertEquals(1234L, json.getLong("filesize"))
    }

    @Test
    fun missingDurationWidthAndHeightAreAbsentNotZero() {
        val json = Utility("video_compress").getMediaInfoJson(ContextWrapper(null), video.path)

        assertNoMetadataJson(json)
    }

    private fun initializedPlugin(): VideoCompressPlugin {
        val plugin = VideoCompressPlugin()
        // The plugin ignores every call until it holds a context and a channel.
        val init = VideoCompressPlugin::class.java.getDeclaredMethod(
            "init", Context::class.java, BinaryMessenger::class.java)
        init.isAccessible = true
        init.invoke(plugin, ContextWrapper(null), NoOpMessenger())
        return plugin
    }

    @Test
    fun getMediaInfoChannelCallAnswersOnceForAFileWithoutMetadata() {
        val result = RecordingResult()

        initializedPlugin().onMethodCall(MethodCall("getMediaInfo", mapOf("path" to video.path)), result)

        assertEquals(listOf("success"), result.answers)
        assertNoMetadataJson(JSONObject(result.successValue as String))
    }

    @Test
    fun getMediaInfoChannelCallThatCannotReadAnswersOneError() {
        val result = RecordingResult()

        // No path: nothing can be read.
        initializedPlugin().onMethodCall(MethodCall("getMediaInfo", emptyMap<String, Any>()), result)

        assertEquals(listOf("error"), result.answers)
    }

    @Test
    fun deleteAllCacheAnswersOnce() {
        val result = RecordingResult()

        // The stub context has no external storage: nothing to delete.
        initializedPlugin().onMethodCall(MethodCall("deleteAllCache", null), result)

        assertEquals(listOf("success"), result.answers)
        assertEquals(null, result.successValue)
    }
}
