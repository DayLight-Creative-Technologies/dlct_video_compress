package com.example.video_compress

import android.media.MediaCodec
import com.otaliastudios.transcoder.common.TrackType
import com.otaliastudios.transcoder.sink.DataSink
import java.nio.ByteBuffer

/**
 * [sink] without any audio sample stamped before an audio sample it already
 * wrote. Transcoder 0.10.5's decoder stamps its end-of-stream output 0 (its
 * Decoder.drain: `if (isEos) 0`); where the AAC decoder still returns sound
 * in that buffer (Android 7.0's OMX.google.aac.decoder does), the encoded
 * frame reaches the muxer stamped 0 after the last one, and Android 7's
 * MPEG4Writer refuses it ("do not support out of order frames ... for Audio
 * track") and takes the media server down with it, so every compress with
 * audio failed there (seen on an API 24 emulator). Newer MPEG4Writers do
 * not stop on it. What is dropped is that one stray frame, at most 23 ms of
 * sound at the very end. Video samples pass unchanged: a video track's
 * presentation times may go back legitimately (B-frames).
 *
 * Called on the transcoder's thread only.
 */
internal class MonotonicAudioDataSink(private val sink: DataSink) : DataSink by sink {
    private var lastAudioUs: Long? = null

    override fun writeTrack(type: TrackType, buffer: ByteBuffer, info: MediaCodec.BufferInfo) {
        if (type == TrackType.AUDIO) {
            val last = lastAudioUs
            if (last != null && info.presentationTimeUs < last) return
            lastAudioUs = info.presentationTimeUs
        }
        sink.writeTrack(type, buffer, info)
    }
}
