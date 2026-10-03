package com.example.video_compress

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import org.json.JSONObject
import java.io.File

/**
 * The metadata strings a [MediaMetadataRetriever] reported for a file, each
 * null where the file has none.
 */
internal data class RawMediaMetadata(
    val duration: String?,
    val title: String?,
    val author: String?,
    val width: String?,
    val height: String?,
    val rotation: String?,
)

/**
 * The part of a source [sourceDurationUs] long that a compress exports, the
 * same rule on every platform (iOS/macOS: `AvController.exportRange`): from
 * [startTime] seconds (default 0) for [duration] seconds (default: to the
 * end), cut at the end of the source, as (start, end) in microseconds. Null
 * when the arguments name no part of the source: a negative start, a start
 * at or past the end, or a duration that is not positive. Pure.
 */
internal fun exportRangeUs(startTime: Long?, duration: Long?, sourceDurationUs: Long): Pair<Long, Long>? {
    val startUs = (startTime ?: 0L) * 1_000_000L
    if (startUs < 0 || startUs >= sourceDurationUs) return null
    if (duration != null && duration <= 0) return null
    val endUs = if (duration == null) sourceDurationUs
        else minOf(startUs + duration * 1_000_000L, sourceDurationUs)
    return Pair(startUs, endUs)
}

class Utility(private val channelName: String) {

    fun deleteFile(file: File) {
        if (file.exists()) {
            file.delete()
        }
    }

    fun timeStrToTimestamp(time: String): Long {
        val timeArr = time.split(":")
        val hour = Integer.parseInt(timeArr[0])
        val min = Integer.parseInt(timeArr[1])
        val secArr = timeArr[2].split(".")
        val sec = Integer.parseInt(secArr[0])
        val mSec = Integer.parseInt(secArr[1])

        val timeStamp = (hour * 3600 + min * 60 + sec) * 1000 + mSec
        return timeStamp.toLong()
    }

    /**
     * The media info of the file at [path]. Metadata the file does not have
     * (a duration, a width, a height, a rotation) is absent from the JSON,
     * never 0. Throws when the file cannot be read as media at all
     * (setDataSource's IllegalArgumentException or RuntimeException). The
     * retriever is released either way; it used to leak when a missing
     * duration, width or height threw from parseLong.
     */
    fun getMediaInfoJson(context: Context, path: String): JSONObject =
        readMediaInfoJson(MediaMetadataRetriever(), context, path)

    /** [getMediaInfoJson] reading through [retriever], which it releases. */
    internal fun readMediaInfoJson(
        retriever: MediaMetadataRetriever,
        context: Context,
        path: String,
    ): JSONObject {
        val file = File(path)
        try {
            retriever.setDataSource(context, Uri.fromFile(file))
            val metadata = RawMediaMetadata(
                duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION),
                title = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE),
                author = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_AUTHOR),
                width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH),
                height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT),
                rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION),
            )
            return mediaInfoJson(path, file.length(), metadata)
        } finally {
            releaseQuietly(retriever)
        }
    }

    /**
     * The media info JSON of the file at [path], [filesize] bytes long, from
     * the strings its retriever reported. A number the file does not report,
     * or reports unparseably, is absent from the JSON; a missing title or
     * author is "". The width and height are the displayed size: the
     * retriever reports the stored size, so a quarter turn (90 or 270) swaps
     * them. (They were swapped for 0 and 180 instead, SSK gap #906.) Pure.
     *
     * The orientation rule, the same on every platform (SSK gap #912): 90,
     * 180 or 270 when the track's transform matrix is exactly that quarter
     * turn, and 0 for every other matrix, a mirror (horizontal, vertical, or
     * across a diagonal) included, with the stored size. Here the retriever
     * applies it: MPEG4Extractor recognizes exactly those four track-header
     * matrices and reports 0 for any other (verified on Android 16: the
     * mirrored fixtures report rotation "0", 64 x 48, and an unmirrored
     * frame). iOS and macOS apply it in `AvController.getVideoOrientation`.
     */
    internal fun mediaInfoJson(path: String, filesize: Long, metadata: RawMediaMetadata): JSONObject {
        var width = metadata.width?.toLongOrNull()
        var height = metadata.height?.toLongOrNull()
        val ori = metadata.rotation?.toIntOrNull()
        if (ori == 90 || ori == 270) {
            val tmp = width
            width = height
            height = tmp
        }

        val json = JSONObject()

        json.put("path", path)
        json.put("title", metadata.title ?: "")
        json.put("author", metadata.author ?: "")
        if (width != null) {
            json.put("width", width)
        }
        if (height != null) {
            json.put("height", height)
        }
        val duration = metadata.duration?.toLongOrNull()
        if (duration != null) {
            json.put("duration", duration)
        }
        json.put("filesize", filesize)
        if (ori != null) {
            json.put("orientation", ori)
        }

        return json
    }

    /** Releases [retriever]; a failure while cleaning up changes no answer. */
    private fun releaseQuietly(retriever: MediaMetadataRetriever) {
        try {
            retriever.release()
        } catch (ex: Exception) {
            // Nothing to do: the read already succeeded or already failed.
        }
    }

    /**
     * The frame at [positionMs] milliseconds (the unit the Dart API documents;
     * it used to be passed to getFrameAtTime as microseconds, so
     * `position: 1000` asked for the frame 1 ms in), scaled to at most 512 px.
     * A negative position is any frame. Null when the frame cannot be read:
     * the caller answers, exactly once. (This used to answer an error AND an
     * unencodable success, then throw on the null bitmap.)
     */
    fun getBitmap(path: String, positionMs: Long): Bitmap? {
        val retriever = MediaMetadataRetriever()
        var bitmap: Bitmap? = try {
            retriever.setDataSource(path)
            val timeUs = if (positionMs < 0) -1L else positionMs * 1000L
            retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
        } catch (ex: RuntimeException) {
            // IllegalArgumentException included: a corrupt or unreadable video.
            null
        } finally {
            releaseQuietly(retriever)
        }

        val frame = bitmap ?: return null
        val width = frame.width
        val height = frame.height
        val max = Math.max(width, height)
        if (max > 512) {
            val scale = 512f / max
            val w = Math.round(scale * width)
            val h = Math.round(scale * height)
            bitmap = Bitmap.createScaledBitmap(frame, w, h, true)
        }

        return bitmap
    }

    fun getFileNameWithGifExtension(path: String): String {
        val file = File(path)
        var fileName = ""
        val gifSuffix = "gif"
        val dotGifSuffix = ".$gifSuffix"

        if (file.exists()) {
            val name = file.name
            fileName = name.replaceAfterLast(".", gifSuffix)

            if (!fileName.endsWith(dotGifSuffix)) {
                fileName += dotGifSuffix
            }
        }
        return fileName
    }

    /**
     * Deletes the compressed-video cache: true when it was deleted, false
     * when not all of it could be, null when there is no external storage.
     */
    fun deleteAllCache(context: Context): Boolean? =
        context.getExternalFilesDir("video_compress")?.deleteRecursively()
}