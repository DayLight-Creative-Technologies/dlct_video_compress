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
