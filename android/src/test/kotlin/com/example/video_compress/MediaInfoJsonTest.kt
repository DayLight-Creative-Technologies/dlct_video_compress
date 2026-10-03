package com.example.video_compress

import android.content.Context
import android.content.ContextWrapper
import android.media.MediaMetadataRetriever
import android.net.Uri
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.fail
import org.junit.Test

/**
 * The media info JSON built from what a [MediaMetadataRetriever] reports
 * ([Utility.mediaInfoJson]), and the retriever's release on every path
 * ([Utility.readMediaInfoJson]).
 */
class MediaInfoJsonTest {

    private val utility = Utility("video_compress")

    /** Reports [metadata] and counts its releases; [failOpen] makes setDataSource throw. */
    private class RecordingRetriever(
        private val metadata: Map<Int, String> = emptyMap(),
        private val failOpen: RuntimeException? = null,
    ) : MediaMetadataRetriever() {
        var releases = 0

        override fun setDataSource(context: Context?, uri: Uri?) {
            failOpen?.let { throw it }
        }

        override fun extractMetadata(keyCode: Int): String? = metadata[keyCode]

        override fun release() {
            releases++
        }
    }

    private fun keys(json: JSONObject): Set<String> = json.keys().asSequence().toSet()

    private fun raw(
        duration: String? = null,
        title: String? = null,
        author: String? = null,
        width: String? = null,
        height: String? = null,
        rotation: String? = null,
    ) = RawMediaMetadata(duration, title, author, width, height, rotation)

    @Test
    fun fullMetadataWithoutRotationIsReportedAsIs() {
        val json = utility.mediaInfoJson("/v.mp4", 4096L,
            raw(duration = "1500", title = "Game", author = "Coach", width = "1920", height = "1080"))

        assertEquals(setOf("path", "title", "author", "width", "height", "duration", "filesize"), keys(json))
        assertEquals("/v.mp4", json.get("path"))
        assertEquals("Game", json.get("title"))
        assertEquals("Coach", json.get("author"))
        assertEquals(1920L, json.get("width"))
        assertEquals(1080L, json.get("height"))
        assertEquals(1500L, json.get("duration"))
        assertEquals(4096L, json.get("filesize"))
    }

    /**
     * The retriever reports the stored (coded) size and the rotation a player
     * applies; the JSON's width and height are the displayed size. A quarter
     * turn swaps them, a half turn does not (gap #906: the swap was applied
     * for 0 and 180 instead).
     */
    @Test
    fun widthAndHeightAreTheDisplayedSizeForEveryRotation() {
        val expected = mapOf(0 to (1920L to 1080L), 90 to (1080L to 1920L),
            180 to (1920L to 1080L), 270 to (1080L to 1920L))
        for ((rotation, size) in expected) {
            val json = utility.mediaInfoJson("/v.mp4", 10L,
                raw(width = "1920", height = "1080", rotation = rotation.toString()))

            assertEquals("width at $rotation", size.first, json.get("width"))
            assertEquals("height at $rotation", size.second, json.get("height"))
            assertEquals("orientation at $rotation", rotation, json.get("orientation"))
        }
    }

    /**
     * The cross-platform orientation rule (gap #912): a transform that is not
     * exactly a quarter turn, a mirror included, reports 0 and the stored
     * size. These are the strings Android 16's retriever reported for
     * native_tests/media_info/fixtures/video_mirror_h.mp4, video_mirror_v.mp4,
     * video_transpose.mp4 and video_antitranspose.mp4 (all stored 64 x 48),
     * and for the quarter-turn fixtures, which keep their turn; iOS and macOS
     * report the same for the same files (native_tests/media_info/main.swift).
     */
    @Test
    fun mirroredTransformsReportNoTurnAndTheStoredSize() {
        val reported = mapOf(
            "video_mirror_h.mp4" to "0", "video_mirror_v.mp4" to "0",
            "video_transpose.mp4" to "0", "video_antitranspose.mp4" to "0",
            "video_rot90.mp4" to "90", "video_rot180.mp4" to "180", "video_rot270.mp4" to "270",
        )
        val expected = mapOf(
            "video_mirror_h.mp4" to Triple(0, 64L, 48L), "video_mirror_v.mp4" to Triple(0, 64L, 48L),
            "video_transpose.mp4" to Triple(0, 64L, 48L), "video_antitranspose.mp4" to Triple(0, 64L, 48L),
            "video_rot90.mp4" to Triple(90, 48L, 64L), "video_rot180.mp4" to Triple(180, 64L, 48L),
            "video_rot270.mp4" to Triple(270, 48L, 64L),
        )
        for ((name, rotation) in reported) {
            val json = utility.mediaInfoJson("/$name", 5201L,
                raw(duration = "1000", width = "64", height = "48", rotation = rotation))
            val (orientation, width, height) = expected.getValue(name)

            assertEquals("orientation of $name", orientation, json.get("orientation"))
            assertEquals("width of $name", width, json.get("width"))
            assertEquals("height of $name", height, json.get("height"))
        }
    }

    @Test
    fun noMetadataLeavesEveryNumberAbsent() {
        val json = utility.mediaInfoJson("/v.mp4", 10L, raw())

        assertEquals(setOf("path", "title", "author", "filesize"), keys(json))
        assertEquals("", json.get("title"))
        assertEquals("", json.get("author"))
        assertEquals(10L, json.get("filesize"))
    }

    @Test
    fun missingDurationAloneIsAbsentAndTheSizeStays() {
        val json = utility.mediaInfoJson("/v.mp4", 10L, raw(width = "640", height = "480"))

        assertEquals(setOf("path", "title", "author", "width", "height", "filesize"), keys(json))
        assertEquals(640L, json.get("width"))
        assertEquals(480L, json.get("height"))
    }

    @Test
    fun unparseableNumbersAreAbsentNotZero() {
        val json = utility.mediaInfoJson("/v.mp4", 10L,
            raw(duration = "", width = "wide", height = "12.5", rotation = "sideways"))

        assertEquals(setOf("path", "title", "author", "filesize"), keys(json))
    }

    @Test
    fun readReleasesTheRetrieverAfterASuccessfulRead() {
        val retriever = RecordingRetriever(mapOf(
            MediaMetadataRetriever.METADATA_KEY_DURATION to "2000",
            MediaMetadataRetriever.METADATA_KEY_TITLE to "Clip",
        ))

        val json = utility.readMediaInfoJson(retriever, ContextWrapper(null), "/missing/v.mp4")

        assertEquals(1, retriever.releases)
        assertEquals(setOf("path", "title", "author", "duration", "filesize"), keys(json))
        assertEquals("Clip", json.get("title"))
        assertEquals(2000L, json.get("duration"))
        assertEquals(0L, json.get("filesize"))
    }

    @Test
    fun readReleasesTheRetrieverWhenTheFileCannotBeRead() {
        val unreadable = IllegalArgumentException("not media")
        val retriever = RecordingRetriever(failOpen = unreadable)

        try {
            utility.readMediaInfoJson(retriever, ContextWrapper(null), "/missing/v.mp4")
            fail("an unreadable file must throw")
        } catch (e: IllegalArgumentException) {
            assertSame(unreadable, e)
        }

        assertEquals(1, retriever.releases)
    }
}
