package com.example.video_compress_example

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.example.video_compress.VideoCompressPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import kotlin.math.abs

/**
 * [DLCT] The real plugin on a device: its method-channel handler, called on
 * the main thread as Flutter calls it, against Android's real
 * MediaMetadataRetriever, MediaCodec and the Transcoder library, on the
 * fixtures native_tests/media_info checks on iOS and macOS (the test APK's
 * assets). Only the channel to Dart is a stand-in: it records the progress
 * the plugin reports.
 */
@RunWith(AndroidJUnit4::class)
class VideoCompressPluginTest {

    /** Every answer one call receives, and a latch for the first. */
    private class Answers : MethodChannel.Result {
        val all = CopyOnWriteArrayList<Pair<String, Any?>>()
        private val first = CountDownLatch(1)

        override fun success(result: Any?) {
            all.add(Pair("success", result))
            first.countDown()
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            all.add(Pair("error", errorMessage))
            first.countDown()
        }

        override fun notImplemented() {
            all.add(Pair("notImplemented", null))
            first.countDown()
        }

        /** Waits up to [seconds] for the first answer; whether one came. */
        fun await(seconds: Long): Boolean = first.await(seconds, TimeUnit.SECONDS)
    }

    /** The channel to Dart: records each progress report. */
    private class RecordingMessenger(val progress: MutableList<Double>) : BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) = send(channel, message, null)

        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            val bytes = message ?: return
            bytes.rewind()
            val call = StandardMethodCodec.INSTANCE.decodeMethodCall(bytes)
            if (call.method == "updateProgress") {
                (call.arguments as? Number)?.let { progress.add(it.toDouble()) }
            }
        }

        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
    }

    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context = instrumentation.targetContext
    private val progress = CopyOnWriteArrayList<Double>()
    private lateinit var plugin: VideoCompressPlugin
    private lateinit var fixtures: File

    @Before
    fun setUp() {
        plugin = VideoCompressPlugin()
        // onAttachedToEngine needs a running engine; the plugin only keeps
        // its context and messenger from it.
        val init = VideoCompressPlugin::class.java.getDeclaredMethod(
            "init", Context::class.java, BinaryMessenger::class.java)
        init.isAccessible = true
        init.invoke(plugin, context, RecordingMessenger(progress))
        fixtures = File(context.cacheDir, "fixtures")
        fixtures.mkdirs()
        outputDir().deleteRecursively()
    }

    @After
    fun tearDown() {
        fixtures.deleteRecursively()
        outputDir().deleteRecursively()
    }

    /** The plugin's output folder. */
    private fun outputDir(): File = context.getExternalFilesDir("video_compress")!!

    /** The compressed videos in the output folder. */
    private fun outputs(): Set<String> =
        outputDir().listFiles()?.map { it.name }?.filter { it.endsWith(".mp4") }?.toSet() ?: emptySet()

    /** The path of fixture [name], copied out of the test APK's assets. */
    private fun fixture(name: String): String {
        val file = File(fixtures, name)
        if (!file.exists()) {
            instrumentation.context.assets.open(name).use { input ->
                file.outputStream().use { input.copyTo(it) }
            }
        }
        return file.path
    }

    /** Calls the plugin's handler on the main thread, as Flutter does. */
    private fun call(method: String, arguments: Map<String, Any?>? = null): Answers {
        val answers = Answers()
        instrumentation.runOnMainSync { plugin.onMethodCall(MethodCall(method, arguments), answers) }
        return answers
    }

    /**
     * Every answer a call receives: the first within [seconds], then any
     * other arriving within the next [settle] milliseconds.
     */
    private fun answersOf(answers: Answers, seconds: Long = 300, settle: Long = 1000): List<Pair<String, Any?>> {
        assertTrue("no answer in $seconds s", answers.await(seconds))
        Thread.sleep(settle)
        instrumentation.waitForIdleSync()
        return answers.all.toList()
    }

    /** The one JSON a call answered. */
    private fun oneJson(what: String, all: List<Pair<String, Any?>>): JSONObject {
        assertEquals("$what: answers $all", 1, all.size)
        assertEquals("$what: answers $all", "success", all[0].first)
        return JSONObject(all[0].second as String)
    }

    private fun compressArguments(path: String, quality: Int, includeAudio: Boolean, frameRate: Int?,
                                  startTime: Int? = null, duration: Int? = null): Map<String, Any?> =
        mapOf("path" to path, "quality" to quality, "deleteOrigin" to false, "includeAudio" to includeAudio,
            "frameRate" to frameRate, "startTime" to startTime, "duration" to duration)

    /** SSK's call: 1920x1080 quality, with audio, 30 fps. */
    private fun sskCompress(name: String): Answers =
        call("compressVideo", compressArguments(fixture(name), 7, true, 30))

    /** The colour of a pixel: red, green, blue, white, or its hex value. */
    private fun colourName(pixel: Int): String {
        val r = (pixel shr 16) and 0xff
        val g = (pixel shr 8) and 0xff
        val b = pixel and 0xff
        return when (Triple(r > 160, g > 160, b > 160)) {
            Triple(true, true, true) -> "white"
            Triple(true, false, false) -> "red"
            Triple(false, true, false) -> "green"
            Triple(false, false, true) -> "blue"
            else -> String.format("#%06x", pixel and 0xffffff)
        }
    }

    /** The colour at the centre of each quadrant: TL, TR, BL, BR. */
    private fun quadrants(bitmap: Bitmap): List<String> {
        val w = bitmap.width
        val h = bitmap.height
        return listOf(Pair(1, 1), Pair(3, 1), Pair(1, 3), Pair(3, 3))
            .map { (qx, qy) -> colourName(bitmap.getPixel(qx * w / 4, qy * h / 4)) }
    }

    /** The frame of [path] at [timeUs] (the closest frame), or null. */
    private fun frame(path: String, timeUs: Long): Bitmap? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST)
        } finally {
            retriever.release()
        }
    }

    /** The colour of the whole frame at [timeUs] (one colour, or each quadrant's). */
    private fun colourAt(path: String, timeUs: Long): String? {
        val bitmap = frame(path, timeUs) ?: return null
        val all = quadrants(bitmap).toSet()
        return if (all.size == 1) all.first() else all.sorted().joinToString("/")
    }

    /** The duration in seconds of each track of [path], by mime prefix ("video/", "audio/"). */
    private fun trackSeconds(path: String): Map<String, Double> {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            val tracks = mutableMapOf<String, Double>()
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                val kind = mime.substringBefore('/') + "/"
                val seconds = if (format.containsKey(MediaFormat.KEY_DURATION))
                    format.getLong(MediaFormat.KEY_DURATION) / 1_000_000.0 else -1.0
                tracks[kind] = seconds
            }
            return tracks
        } finally {
            extractor.release()
        }
    }

    // ---------------------------------------------------------------- media info

    /**
     * getMediaInfo on the turned and mirrored fixtures: the orientation rule
     * (a quarter turn reports that turn and the size turned by it; any other
     * transform, a mirror included, reports 0 and the stored size), from
     * Android's real MediaMetadataRetriever. The same expectations as
     * native_tests/media_info/main.swift on iOS and macOS.
     */
    @Test
    fun mediaInfoFollowsTheOrientationRule() {
        val expected = listOf(
            Triple("video_quadrants.mp4", 0, Pair(64, 48)),
            Triple("video_rot90.mp4", 90, Pair(48, 64)),
            Triple("video_rot180.mp4", 180, Pair(64, 48)),
            Triple("video_rot270.mp4", 270, Pair(48, 64)),
            Triple("video_mirror_h.mp4", 0, Pair(64, 48)),
            Triple("video_mirror_v.mp4", 0, Pair(64, 48)),
            Triple("video_transpose.mp4", 0, Pair(64, 48)),
            Triple("video_antitranspose.mp4", 0, Pair(64, 48)),
            Triple("video_audio_first.mp4", 0, Pair(64, 48)),
        )
        for ((name, orientation, size) in expected) {
            val path = fixture(name)
            val json = oneJson("getMediaInfo $name", answersOf(call("getMediaInfo", mapOf("path" to path)), settle = 0))
            assertEquals("$name: path", path, json.getString("path"))
            assertEquals("$name: orientation $json", orientation, json.getInt("orientation"))
            assertEquals("$name: width $json", size.first, json.getInt("width"))
            assertEquals("$name: height $json", size.second, json.getInt("height"))
            assertTrue("$name: duration $json", abs(json.getLong("duration") - 1000) <= 50)
            assertEquals("$name: filesize $json", File(path).length(), json.getLong("filesize"))
        }
    }

    @Test
    fun mediaInfoOfAnUnreadableFileIsOneError() {
        for (name in listOf("not_media.mp4", "empty.mp4")) {
            val all = answersOf(call("getMediaInfo", mapOf("path" to fixture(name))), settle = 0)
            assertEquals("$name: $all", listOf(Pair("error", "getMediaInfo error")), all)
        }
    }

    // ---------------------------------------------------------------- thumbnails

    /**
     * getFileThumbnail writes one JPEG of the frame as Android's retriever
     * shows it: turned by a quarter, half or three-quarter turn, and a
     * mirror shown unmirrored (CHANGELOG 3.1.5+dlct.7).
     */
    @Test
    fun fileThumbnailIsTheDisplayedFrame() {
        val expected = listOf(
            Triple("video_quadrants.mp4", Pair(64, 48), listOf("red", "green", "blue", "white")),
            Triple("video_rot90.mp4", Pair(48, 64), listOf("blue", "red", "white", "green")),
            Triple("video_rot180.mp4", Pair(64, 48), listOf("white", "blue", "green", "red")),
            Triple("video_rot270.mp4", Pair(48, 64), listOf("green", "white", "red", "blue")),
            Triple("video_mirror_h.mp4", Pair(64, 48), listOf("red", "green", "blue", "white")),
        )
        for ((name, size, colours) in expected) {
            val all = answersOf(call("getFileThumbnail",
                mapOf("path" to fixture(name), "quality" to 100, "position" to 0)), settle = 0)
            assertEquals("$name: $all", 1, all.size)
            assertEquals("$name: $all", "success", all[0].first)
            val file = File(all[0].second as String)
            assertTrue("$name: no file at $file", file.exists())
            val options = BitmapFactory.Options()
            val bitmap = BitmapFactory.decodeFile(file.path, options)
            assertNotNull("$name: not an image", bitmap)
            assertEquals("$name: type", "image/jpeg", options.outMimeType)
            assertEquals("$name: size", size, Pair(bitmap.width, bitmap.height))
            assertEquals("$name: quadrants", colours, quadrants(bitmap))
            file.delete()
        }
    }

    // ---------------------------------------------------------------- compress

    /**
     * How far an Android output's length may be from the length asked for,
     * in seconds. Measured on the Android 16 emulator, untrimmed and
     * trimmed alike: an AAC track runs up to 0.11 s long (Android's encoder
     * padding stays in the file: MediaMuxer writes no edit that hides it, as
     * AVFoundation does), and a video track ends up to 0.17 s short. On the
     * emulator only about half the decoded frames reach the encoder (156 of
     * 300 for SSK's call on video_long.mp4, with Transcoder's FrameDropper
     * rendering every frame it is handed), and a frame next to a colour
     * change can carry its neighbour's picture, so the colour checks sample
     * inside each part. The exact end of each track is pinned by
     * EndTrimDataSourceTest, on the JVM.
     */
    private val lengthTolerance = 0.2

    /** SSK's call compresses for real: one answer, a readable output of the input's length. */
    @Test
    fun sskCompressProducesTheVideo() {
        for ((name, seconds) in listOf(Pair("video_quadrants.mp4", 1.0), Pair("video_long.mp4", 10.0))) {
            val json = oneJson("compress $name", answersOf(sskCompress(name)))
            assertFalse("$name: isCancel $json", json.getBoolean("isCancel"))
            val path = json.getString("path")
            assertTrue("$name: no file at $path", File(path).exists())
            val tracks = trackSeconds(path)
            val answered = json.getLong("duration") / 1000.0
            assertTrue("$name: answered duration $answered s, expected $seconds s (tracks $tracks)",
                abs(answered - seconds) <= lengthTolerance)
            assertTrue("$name: tracks $tracks", tracks.containsKey("video/") && tracks.containsKey("audio/"))
            assertTrue("$name: video track $tracks, expected $seconds s",
                abs(tracks.getValue("video/") - seconds) <= lengthTolerance)
            assertTrue("$name: audio track $tracks, expected $seconds s",
                abs(tracks.getValue("audio/") - seconds) <= lengthTolerance)
            if (name == "video_quadrants.mp4") {
                assertEquals("$name: output frame", listOf("red", "green", "blue", "white"),
                    quadrants(frame(path, 500_000)!!))
            } else {
                // Red with the white bar at the left edge.
                assertEquals("$name: first frame", "red", colourName(frame(path, 0)!!.let {
                    it.getPixel(it.width / 2, it.height / 2)
                }))
            }
            File(path).delete()
        }
    }

    /**
     * startTime and duration on video_timed.mp4 (3 s: red, green, blue, a
     * second each), with audio and without: the output is the requested part,
     * cut at the end of the video, and its first and last frames are the
     * colours at its start and end. The rule iOS and macOS apply too
     * (native_tests/media_info/main.swift checkTrim). Until 3.1.5+dlct.8 the
     * duration was passed as the part to cut from the END (SSK gap #913),
     * and a part's end was where the fastest track passed it (a video-only
     * [1 s, 2 s) ended on a blue frame).
     */
    @Test
    fun compressExportsTheRequestedPart() {
        val trims = listOf(
            listOf(null, null, 3.0, "red", "blue"),
            listOf(1, 1, 1.0, "green", "green"),
            listOf(0, 1, 1.0, "red", "red"),
            listOf(2, null, 1.0, "blue", "blue"),
            listOf(null, 2, 2.0, "red", "green"),
            listOf(1, 5, 2.0, "green", "blue"),
        )
        val path = fixture("video_timed.mp4")
        for (includeAudio in listOf(true, false)) {
            for (trim in trims) {
                val start = trim[0] as Int?
                val length = trim[1] as Int?
                val seconds = trim[2] as Double
                val what = "startTime $start duration $length audio $includeAudio"
                val json = oneJson(what, answersOf(call("compressVideo",
                    compressArguments(path, 0, includeAudio, 30, start, length))))
                val output = json.getString("path")
                val tracks = trackSeconds(output)
                val answered = json.getLong("duration") / 1000.0
                assertTrue("$what: answered duration $answered s, expected $seconds s (tracks $tracks)",
                    abs(answered - seconds) <= lengthTolerance)
                assertTrue("$what: video track $tracks, expected $seconds s",
                    abs((tracks["video/"] ?: -1.0) - seconds) <= lengthTolerance)
                assertEquals("$what: audio track $tracks", includeAudio, tracks.containsKey("audio/"))
                if (includeAudio) {
                    assertTrue("$what: audio track $tracks, expected $seconds s",
                        abs(tracks.getValue("audio/") - seconds) <= lengthTolerance)
                }
                assertEquals("$what: first frame", trim[3], colourAt(output, 0))
                // 0.1 s before the end: on the emulator the frames next to a
                // colour change can show their neighbour's colour (see
                // lengthTolerance). Exactly where each track ends is
                // EndTrimDataSourceTest's.
                assertEquals("$what: frame 0.1 s before the end", trim[4],
                    colourAt(output, ((seconds - 0.1) * 1_000_000).toLong()))
                File(output).delete()
            }
            for ((start, length) in listOf(Pair(3, null), Pair(4, 1), Pair(-1, null), Pair(0, 0), Pair(null, -1))) {
                val all = answersOf(call("compressVideo",
                    compressArguments(path, 0, includeAudio, 30, start, length)))
                assertEquals("startTime $start duration $length audio $includeAudio: $all",
                    listOf(Pair("error", "compressVideo error")), all)
            }
        }
        assertEquals("outputs left", emptySet<String>(), outputs())
    }

    // ---------------------------------------------------------------- cancel

    private fun assertOneCancel(what: String, all: List<Pair<String, Any?>>) {
        val json = oneJson(what, all)
        assertEquals("$what: $json", 1, json.length())
        assertTrue("$what: $json", json.getBoolean("isCancel"))
    }

    /** A compress after a cancel completes normally: nothing is inherited. */
    private fun assertNextCompressCompletes(what: String) {
        val json = oneJson("compress after $what", answersOf(sskCompress("video_quadrants.mp4")))
        assertFalse("compress after $what: $json", json.getBoolean("isCancel"))
        assertTrue("compress after $what: $json", File(json.getString("path")).exists())
        File(json.getString("path")).delete()
    }

    @Test
    fun cancelWithNothingRunningAnswersOnce() {
        val all = answersOf(call("cancelCompression"), settle = 200)
        assertEquals(listOf(Pair("success", false)), all)
        assertNextCompressCompletes("a cancel with nothing running")
    }

    /** A cancel in the same main-thread turn as the compress, before its transcode starts. */
    @Test
    fun cancelJustAfterTheStartAnswersCancelledOnce() {
        val compress = Answers()
        val cancel = Answers()
        instrumentation.runOnMainSync {
            plugin.onMethodCall(MethodCall("compressVideo",
                compressArguments(fixture("video_long.mp4"), 7, true, 30)), compress)
            plugin.onMethodCall(MethodCall("cancelCompression", null), cancel)
        }
        assertEquals(listOf(Pair("success", false)), answersOf(cancel, settle = 0))
        assertOneCancel("cancel just after the start", answersOf(compress, settle = 3000))
        assertEquals("outputs left", emptySet<String>(), outputs())
        assertNextCompressCompletes("a cancel just after the start")
    }

    @Test
    fun cancelDuringTheTranscodeAnswersCancelledOnce() {
        val compress = sskCompress("video_long.mp4")
        val deadline = System.currentTimeMillis() + 300_000
        while (progress.none { it > 0 && it < 100 } && compress.all.isEmpty() && System.currentTimeMillis() < deadline) {
            Thread.sleep(10)
        }
        assertTrue("no progress before the answer ${compress.all} (progress $progress)",
            compress.all.isEmpty() && progress.any { it > 0 && it < 100 })
        val cancel = call("cancelCompression")
        assertEquals(listOf(Pair("success", false)), answersOf(cancel, settle = 0))
        assertOneCancel("cancel during the transcode", answersOf(compress, settle = 3000))
        assertEquals("outputs left", emptySet<String>(), outputs())
        assertNextCompressCompletes("a cancel during the transcode")
    }

    /** A field of the compress the plugin is running, read by reflection; null when none runs. */
    private fun runningField(name: String): Any? {
        val pendingField = VideoCompressPlugin::class.java.getDeclaredField("pending")
        pendingField.isAccessible = true
        val pending = pendingField.get(plugin) ?: return null
        val field = pending.javaClass.getDeclaredField(name)
        field.isAccessible = true
        return field.get(pending)
    }

    /**
     * A cancel that arrives after the transcode has completed but before its
     * completion callback has answered: the main thread is held until the
     * transcode is done, so the callback (posted to the main thread) runs
     * only after the cancel. The cancel answers; the completion is ignored
     * and its output deleted. (Until 3.1.5+dlct.8 the cancel answered nothing
     * here and the completion answered the path the caller had cancelled.)
     *
     * The input is audio only: a video transcode needs the main thread while
     * it runs (its decoder surface reports each frame there), so holding the
     * main thread would fail it instead of letting it complete.
     */
    @Test
    fun cancelRacingTheCompletionAnswersCancelledOnce() {
        val compress = Answers()
        val cancel = Answers()
        var completedOutputMs: String? = null
        instrumentation.runOnMainSync {
            plugin.onMethodCall(MethodCall("compressVideo",
                compressArguments(fixture("audio_only.m4a"), 0, true, 30)), compress)
            val future = runningField("future") as Future<*>?
            val destPath = runningField("destPath") as String?
            val deadline = System.currentTimeMillis() + 300_000
            while (future != null && !future.isDone && System.currentTimeMillis() < deadline) {
                Thread.sleep(10)
            }
            // A completed transcode has finished its file: it reads as media.
            if (future?.isDone == true && !future.isCancelled && destPath != null) {
                val retriever = MediaMetadataRetriever()
                try {
                    retriever.setDataSource(destPath)
                    completedOutputMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                } catch (e: RuntimeException) {
                    completedOutputMs = null
                } finally {
                    retriever.release()
                }
            }
            plugin.onMethodCall(MethodCall("cancelCompression", null), cancel)
        }
        assertTrue("the transcode did not complete while the main thread waited (output $completedOutputMs ms)",
            completedOutputMs?.toLongOrNull()?.let { abs(it - 1000) <= 200 } == true)
        assertEquals(listOf(Pair("success", false)), answersOf(cancel, settle = 0))
        assertOneCancel("cancel racing the completion", answersOf(compress, settle = 2000))
        assertEquals("outputs left", emptySet<String>(), outputs())
        assertNextCompressCompletes("a cancel racing the completion")
    }
}
