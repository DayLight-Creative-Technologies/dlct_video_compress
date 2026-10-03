package com.example.video_compress

import android.content.Context
import android.media.MediaExtractor
import android.net.Uri
import com.otaliastudios.transcoder.common.TrackType
import com.otaliastudios.transcoder.source.DataSource
import com.otaliastudios.transcoder.source.DataSourceWrapper
import com.otaliastudios.transcoder.source.TrimDataSource

/**
 * [source] ending at [endUs] on every track: each sample stamped at or after
 * [endUs] (the extractor's clock, the time each chunk carries) is still read,
 * so the samples of the other tracks behind it can be, but not rendered (the
 * decoders drop what is not rendered), and the source is drained once every
 * selected track has reached [endUs]. Its duration is [durationUs], the
 * length kept.
 *
 * Transcoder's own end trim (TrimDataSource's trimEndUs) drains the whole
 * source once its FASTEST track passes the end: with audio, the audio read
 * ahead ends the video up to 0.2 s early, and without, the frames already
 * read still pass, ending up to 0.15 s late (measured on Android 16 with
 * native_tests/media_info/fixtures/video_timed.mp4). This ends each track at
 * its own last sample before [endUs], as an export range does on iOS and
 * macOS. The start is TrimDataSource's, which is already exact: it seeks to
 * the key frame before the start and does not render up to the start.
 *
 * Its state is read and written on the transcoder's thread only.
 */
internal class EndTrimDataSource(
    source: DataSource,
    private val endUs: Long,
    private val durationUs: Long,
) : DataSourceWrapper(source) {
    private val selected = mutableSetOf<TrackType>()
    private val ended = mutableSetOf<TrackType>()
    /** The track the reader last found readable: the one readTrack reads. */
    private var readable: TrackType? = null

    override fun selectTrack(type: TrackType) {
        selected.add(type)
        super.selectTrack(type)
    }

    override fun releaseTrack(type: TrackType) {
        selected.remove(type)
        ended.remove(type)
        super.releaseTrack(type)
    }

    override fun canReadTrack(type: TrackType): Boolean {
        val can = super.canReadTrack(type)
        if (can) readable = type
        return can
    }

    override fun readTrack(chunk: DataSource.Chunk) {
        super.readTrack(chunk)
        if (chunk.timeUs >= endUs) {
            chunk.render = false
            readable?.let { ended.add(it) }
        }
    }

    override fun isDrained(): Boolean =
        super.isDrained() || (selected.isNotEmpty() && ended.containsAll(selected))

    override fun getDurationUs(): Long = durationUs

    override fun getPositionUs(): Long = minOf(super.getPositionUs(), durationUs)

    override fun deinitialize() {
        selected.clear()
        ended.clear()
        readable = null
        super.deinitialize()
    }
}

/**
 * [source] trimmed to [rangeUs] (exportRangeUs: start and end from the
 * source's first sample), whose first sample is at [originUs] on the
 * extractor's clock: TrimDataSource starts it, at the key frame before the
 * start without rendering up to it, and EndTrimDataSource ends every track
 * at its end.
 */
internal fun trimmedSource(source: DataSource, rangeUs: Pair<Long, Long>, originUs: Long): DataSource =
    EndTrimDataSource(TrimDataSource(source, rangeUs.first, 0),
        originUs + rangeUs.second, rangeUs.second - rangeUs.first)

/**
 * The time of the first sample of the media at [uri] with every track
 * selected: the origin of the clock its chunks carry, found as Transcoder's
 * DefaultDataSource finds it. Throws when the media cannot be read.
 */
internal fun firstSampleTimeUs(context: Context, uri: Uri): Long {
    val extractor = MediaExtractor()
    try {
        extractor.setDataSource(context, uri, null)
        for (i in 0 until extractor.trackCount) extractor.selectTrack(i)
        return extractor.sampleTime
    } finally {
        extractor.release()
    }
}
