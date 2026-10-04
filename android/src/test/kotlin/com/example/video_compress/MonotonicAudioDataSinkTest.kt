package com.example.video_compress

import android.media.MediaCodec
import android.media.MediaFormat
import com.otaliastudios.transcoder.common.TrackStatus
import com.otaliastudios.transcoder.common.TrackType
import com.otaliastudios.transcoder.sink.DataSink
import org.junit.Assert.assertEquals
import org.junit.Test
import java.nio.ByteBuffer

/**
 * [MonotonicAudioDataSink] passes every sample to its sink except an audio
 * sample stamped before the last audio sample written: the frame Transcoder
 * stamps 0 at the end of the stream, which Android 7's muxer refuses
 * (the device test `audioOnlyCompressKeepsItsSound` fails on API 24
 * without it).
 */
class MonotonicAudioDataSinkTest {

    /** Records the (track, time) of each sample written. */
    private class RecordingSink : DataSink {
        val written = mutableListOf<Pair<TrackType, Long>>()
        override fun setOrientation(orientation: Int) {}
        override fun setLocation(latitude: Double, longitude: Double) {}
        override fun setTrackStatus(type: TrackType, status: TrackStatus) {}
        override fun setTrackFormat(type: TrackType, format: MediaFormat) {}
        override fun writeTrack(type: TrackType, byteBuffer: ByteBuffer, bufferInfo: MediaCodec.BufferInfo) {
            written.add(Pair(type, bufferInfo.presentationTimeUs))
        }
        override fun stop() {}
        override fun release() {}
    }

    private fun write(sink: DataSink, type: TrackType, timeUs: Long) {
        val info = MediaCodec.BufferInfo()
        info.presentationTimeUs = timeUs
        sink.writeTrack(type, ByteBuffer.allocate(1), info)
    }

    @Test
    fun anAudioSampleStampedBeforeTheLastIsDropped() {
        val recording = RecordingSink()
        val sink = MonotonicAudioDataSink(recording)
        write(sink, TrackType.AUDIO, 0)
        write(sink, TrackType.AUDIO, 975_238)
        write(sink, TrackType.AUDIO, 998_458)
        // The end of the stream, stamped 0.
        write(sink, TrackType.AUDIO, 0)

        assertEquals(listOf(0L, 975_238L, 998_458L).map { Pair(TrackType.AUDIO, it) }, recording.written)
    }

    @Test
    fun audioSamplesInOrderOrAtTheSameTimeAllPass() {
        val recording = RecordingSink()
        val sink = MonotonicAudioDataSink(recording)
        listOf(0L, 23_220L, 23_220L, 46_440L).forEach { write(sink, TrackType.AUDIO, it) }

        assertEquals(4, recording.written.size)
    }

    @Test
    fun videoSamplesPassWhateverTheirOrder() {
        val recording = RecordingSink()
        val sink = MonotonicAudioDataSink(recording)
        // Decode order with B-frames, and audio between them.
        write(sink, TrackType.VIDEO, 0)
        write(sink, TrackType.AUDIO, 10_000)
        write(sink, TrackType.VIDEO, 100_000)
        write(sink, TrackType.VIDEO, 33_333)
        write(sink, TrackType.VIDEO, 66_666)

        assertEquals(listOf(0L, 100_000L, 33_333L, 66_666L),
            recording.written.filter { it.first == TrackType.VIDEO }.map { it.second })
    }
}
