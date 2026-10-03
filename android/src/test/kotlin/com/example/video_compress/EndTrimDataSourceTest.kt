package com.example.video_compress

import android.media.MediaFormat
import com.otaliastudios.transcoder.common.TrackType
import com.otaliastudios.transcoder.source.DataSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer

/**
 * [EndTrimDataSource] ends every track at its own last sample before the
 * end, driven the way Transcoder's Reader drives a source: while it is not
 * drained, each track whose sample is next is read, and a chunk that is not
 * rendered is dropped by the decoder. Transcoder's own end trim drained the
 * whole source when its fastest track passed the end (SSK gap #913).
 */
class EndTrimDataSourceTest {

    /**
     * A source whose samples, in file order, are [samples]: one cursor over
     * the selected tracks, like MediaExtractor. Drained when none is left.
     */
    private class FakeSource(private val samples: List<Pair<TrackType, Long>>) : DataSource {
        private val selected = mutableSetOf<TrackType>()
        private var next = 0
        val positions = mutableMapOf<TrackType, Long>()

        private fun skipUnselected() {
            while (next < samples.size && samples[next].first !in selected) next++
        }

        override fun initialize() {}
        override fun deinitialize() {}
        override fun isInitialized() = true
        override fun getOrientation() = 0
        override fun getLocation(): DoubleArray? = null
        override fun getDurationUs() = 3_000_000L
        override fun getTrackFormat(type: TrackType): MediaFormat? = null
        override fun selectTrack(type: TrackType) {
            selected.add(type)
        }
        /** To the first sample at or after [desiredPositionUs] (every sample a key frame). */
        override fun seekTo(desiredPositionUs: Long): Long {
            next = samples.indexOfFirst { it.second >= desiredPositionUs }.let { if (it < 0) samples.size else it }
            skipUnselected()
            return if (next < samples.size) samples[next].second else desiredPositionUs
        }
        override fun canReadTrack(type: TrackType): Boolean {
            skipUnselected()
            return next < samples.size && samples[next].first == type
        }
        override fun readTrack(chunk: DataSource.Chunk) {
            skipUnselected()
            val (type, timeUs) = samples[next++]
            chunk.timeUs = timeUs
            chunk.render = true
            positions[type] = timeUs
        }
        override fun getPositionUs() = positions.values.maxOrNull() ?: 0L
        override fun isDrained(): Boolean {
            skipUnselected()
            return next >= samples.size
        }
        override fun releaseTrack(type: TrackType) {
            selected.remove(type)
        }
    }

    /** Video at 30 fps and audio every 23 ms for 3 s, in time order (audio first on a tie). */
    private fun interleaved(): List<Pair<TrackType, Long>> {
        val video = (0 until 90).map { Pair(TrackType.VIDEO, it * 1_000_000L / 30) }
        val audio = (0 until 130).map { Pair(TrackType.AUDIO, it * 23_220L) }
        return (audio + video).sortedBy { it.second }
    }

    /** Reads [source] as Transcoder's readers do; the times rendered per track. */
    private fun drive(source: DataSource, tracks: List<TrackType>): Map<TrackType, List<Long>> {
        tracks.forEach { source.selectTrack(it) }
        val rendered = tracks.associateWith { mutableListOf<Long>() }
        val chunk = DataSource.Chunk().apply { buffer = ByteBuffer.allocate(1) }
        var steps = 0
        while (!source.isDrained) {
            assertTrue("no track readable before the source drained", tracks.any { source.canReadTrack(it) })
            for (type in tracks) {
                if (!source.isDrained && source.canReadTrack(type)) {
                    source.readTrack(chunk)
                    if (chunk.render) rendered.getValue(type).add(chunk.timeUs)
                }
            }
            assertTrue(++steps < 10_000)
        }
        return rendered
    }

    @Test
    fun withAudioEachTrackEndsAtItsLastSampleBeforeTheEnd() {
        val end = 1_000_000L
        val rendered = drive(EndTrimDataSource(FakeSource(interleaved()), end, end),
            listOf(TrackType.VIDEO, TrackType.AUDIO))

        // Every video frame before 1 s (30 frames), not one after; the same
        // for audio, although audio reaches 1 s first.
        assertEquals((0 until 30).map { it * 1_000_000L / 30 }, rendered[TrackType.VIDEO])
        assertEquals((0 until 44).map { it * 23_220L }, rendered[TrackType.AUDIO])
    }

    @Test
    fun videoOnlyEndsAtTheLastFrameBeforeTheEnd() {
        val end = 2_000_000L
        val rendered = drive(EndTrimDataSource(FakeSource(interleaved()), end, end), listOf(TrackType.VIDEO))

        assertEquals((0 until 60).map { it * 1_000_000L / 30 }, rendered[TrackType.VIDEO])
    }

    @Test
    fun anEndPastTheLastSampleKeepsEverySample() {
        val rendered = drive(EndTrimDataSource(FakeSource(interleaved()), 5_000_000L, 5_000_000L),
            listOf(TrackType.VIDEO, TrackType.AUDIO))

        assertEquals(90, rendered.getValue(TrackType.VIDEO).size)
        assertEquals(130, rendered.getValue(TrackType.AUDIO).size)
    }

    @Test
    fun notDrainedUntilEveryTrackHasReachedTheEnd() {
        val end = 1_000_000L
        val source = EndTrimDataSource(FakeSource(interleaved()), end, end)
        source.selectTrack(TrackType.VIDEO)
        source.selectTrack(TrackType.AUDIO)
        val chunk = DataSource.Chunk().apply { buffer = ByteBuffer.allocate(1) }
        // The tracks in the order they first read a sample at or past the end.
        val pastEnd = mutableListOf<TrackType>()
        while (!source.isDrained) {
            val type = if (source.canReadTrack(TrackType.AUDIO)) TrackType.AUDIO else TrackType.VIDEO
            assertTrue(source.canReadTrack(type))
            source.readTrack(chunk)
            if (chunk.timeUs >= end && type !in pastEnd) {
                pastEnd.add(type)
                // One track at the end does not drain the source; both do.
                assertEquals(pastEnd.size == 2, source.isDrained)
            }
        }
        // Video's frame at 1 s comes before audio's first sample after it
        // (1.0217 s): the source ran on past the first track's end.
        assertEquals(listOf(TrackType.VIDEO, TrackType.AUDIO), pastEnd)
    }

    /**
     * What the plugin exports for startTime 1, duration 1 (trimmedSource):
     * every sample in [1 s, 2 s) of both tracks, and none other. With
     * TrimDataSource's own end trim (the part cut from the end, 1 s) the
     * video stopped where the audio, read ahead, passed 2 s.
     */
    @Test
    fun theTrimmedSourceIsExactlyTheRangeOnEveryTrack() {
        val source = trimmedSource(FakeSource(interleaved()), Pair(1_000_000L, 2_000_000L), 0L)
        source.initialize()
        assertEquals(1_000_000L, source.durationUs)
        val rendered = drive(source, listOf(TrackType.VIDEO, TrackType.AUDIO))

        assertEquals((30 until 60).map { it * 1_000_000L / 30 }, rendered[TrackType.VIDEO])
        assertEquals((44 until 87).map { it * 23_220L }, rendered[TrackType.AUDIO])
    }

    @Test
    fun theTrimmedSourceEndsOnTheExtractorsClock() {
        // A source whose first sample is at 0.5 s: the end is 0.5 s later on
        // the clock its chunks carry.
        val samples = interleaved().map { Pair(it.first, it.second + 500_000L) }
        val source = trimmedSource(FakeSource(samples), Pair(0L, 1_000_000L), 500_000L)
        source.initialize()
        val rendered = drive(source, listOf(TrackType.VIDEO))

        assertEquals((0 until 30).map { it * 1_000_000L / 30 + 500_000L }, rendered[TrackType.VIDEO])
    }

    @Test
    fun theDurationIsTheLengthKeptAndThePositionStopsThere() {
        val source = EndTrimDataSource(FakeSource(interleaved()), 1_000_000L, 1_000_000L)
        assertEquals(1_000_000L, source.durationUs)
        drive(source, listOf(TrackType.VIDEO, TrackType.AUDIO))
        assertEquals(1_000_000L, source.positionUs)
    }
}
