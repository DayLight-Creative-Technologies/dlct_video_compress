package com.example.video_compress

import android.content.Context
import android.net.Uri
import android.util.Log
import com.otaliastudios.transcoder.Transcoder
import com.otaliastudios.transcoder.TranscoderListener
import com.otaliastudios.transcoder.source.DataSource
import com.otaliastudios.transcoder.source.UriDataSource
import com.otaliastudios.transcoder.strategy.DefaultAudioStrategy
import com.otaliastudios.transcoder.strategy.DefaultVideoStrategy
import com.otaliastudios.transcoder.strategy.RemoveTrackStrategy
import com.otaliastudios.transcoder.strategy.TrackStrategy
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import com.otaliastudios.transcoder.internal.utils.Logger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.Future

/**
 * VideoCompressPlugin
 */
class VideoCompressPlugin : MethodCallHandler, FlutterPlugin {


    private var _context: Context? = null
    private var _channel: MethodChannel? = null
    private val TAG = "VideoCompressPlugin"
    private val LOG = Logger(TAG)
    /**
     * The compress running now, if any: what `cancelCompression` stops.
     * Read and written on the main thread only.
     */
    private var pending: PendingCompress? = null
    var channelName = "video_compress"

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = _context;
        val channel = _channel;

        if (context == null || channel == null) {
            Log.w(TAG, "Calling VideoCompress plugin before initialization")
            return
        }

        when (call.method) {
            "getByteThumbnail" -> {
                val path = call.argument<String>("path")
                val quality = call.argument<Int>("quality")!!
                val position = call.argument<Int>("position")!! // to long
                ThumbnailUtility(channelName).getByteThumbnail(path!!, quality, position.toLong(), result)
            }
            "getFileThumbnail" -> {
                val path = call.argument<String>("path")
                val quality = call.argument<Int>("quality")!!
                val position = call.argument<Int>("position")!! // to long
                ThumbnailUtility("video_compress").getFileThumbnail(context, path!!, quality,
                        position.toLong(), result)
            }
            "getMediaInfo" -> {
                // Answered exactly once: the info, or an error when the file
                // cannot be read as media at all. (A read that threw used to
                // escape the handler unanswered by the plugin.)
                val json = try {
                    Utility(channelName).getMediaInfoJson(context, call.argument<String>("path")!!)
                } catch (e: Exception) {
                    result.error(channelName, "getMediaInfo error", e.message)
                    return
                }
                result.success(json.toString())
            }
            "deleteAllCache" -> {
                // Answered once. (Utility.deleteAllCache used to answer too,
                // so every call was answered twice.)
                result.success(Utility(channelName).deleteAllCache(context))
            }
            "setLogLevel" -> {
                val logLevel = call.argument<Int>("logLevel")!!
                Logger.setLogLevel(logLevel)
                result.success(true);
            }
            "cancelCompression" -> {
                // A compress not answered yet is answered here, once, as
                // cancelled, the same rule as on iOS and macOS: a transcode
                // cancelled before its worker started never reaches a
                // listener callback, and one that finished but whose callback
                // has not run yet would otherwise answer a path the caller
                // asked to cancel (it used to: the cancel answered only when
                // Future.cancel stopped the transcode). The engine's later
                // callbacks only clean up.
                val running = pending
                if (running != null) {
                    running.future?.cancel(true)
                    pending = null
                    File(running.destPath).delete()
                    running.answer { it.success(cancelledJson()) }
                }
                result.success(false);
            }
            "compressVideo" -> {
                val path = call.argument<String>("path")!!
                val quality = call.argument<Int>("quality")!!
                val deleteOrigin = call.argument<Boolean>("deleteOrigin")!!
                // Whole seconds from Dart: an Integer, or a Long past 2^31.
                val startTime = call.argument<Number>("startTime")?.toLong()
                val duration = call.argument<Number>("duration")?.toLong()
                val includeAudio = call.argument<Boolean>("includeAudio") ?: true
                val frameRate = if (call.argument<Int>("frameRate")==null) 30 else call.argument<Int>("frameRate")

                val tempDir: String = context.getExternalFilesDir("video_compress")!!.absolutePath
                val out = SimpleDateFormat("yyyy-MM-dd hh-mm-ss").format(Date())
                // The UUID keeps two compresses of one video in the same
                // second apart: a cancelled transcode still winding down
                // deletes its own output, never the next compress's.
                val destPath: String = tempDir + File.separator + "VID_" + out + path.hashCode() +
                        "_" + UUID.randomUUID() + ".mp4"

                var videoTrackStrategy: TrackStrategy = DefaultVideoStrategy.atMost(340).build();
                val audioTrackStrategy: TrackStrategy

                when (quality) {

                    0 -> {
                      videoTrackStrategy = DefaultVideoStrategy.atMost(720).build()
                    }

                    1 -> {
                        videoTrackStrategy = DefaultVideoStrategy.atMost(360).build()
                    }
                    2 -> {
                        videoTrackStrategy = DefaultVideoStrategy.atMost(640).build()
                    }
                    3 -> {

                        assert(value = frameRate != null)
                        videoTrackStrategy = DefaultVideoStrategy.Builder()
                                .keyFrameInterval(3f)
                                .bitRate(1280 * 720 * 4.toLong())
                                .frameRate(frameRate!!) // will be capped to the input frameRate
                                .build()
                    }
                    4 -> {
                        videoTrackStrategy = DefaultVideoStrategy.atMost(480, 640).build()
                    }
                    5 -> {
                        videoTrackStrategy = DefaultVideoStrategy.atMost(540, 960).build()
                    }
                    6 -> {
                        videoTrackStrategy = DefaultVideoStrategy.atMost(720, 1280).build()
                    }
                    7 -> {
                        videoTrackStrategy = DefaultVideoStrategy.atMost(1080, 1920).build()
                    }                    
                }

                audioTrackStrategy = if (includeAudio) {
                    val sampleRate = DefaultAudioStrategy.SAMPLE_RATE_AS_INPUT
                    val channels = DefaultAudioStrategy.CHANNELS_AS_INPUT

                    DefaultAudioStrategy.builder()
                        .channels(channels)
                        .sampleRate(sampleRate)
                        .build()
                } else {
                    RemoveTrackStrategy()
                }

                // The part exported (exportRangeUs, the rule iOS and macOS
                // apply too; trimmedSource). (TrimDataSource's third
                // argument is how much to cut from the END; it used to be
                // given the duration, so a compress kept everything but the
                // last `duration` seconds, and failed when the duration was
                // longer than the rest of the video, SSK gap #913.)
                val uri = Uri.parse(path)
                val source = UriDataSource(context, uri)
                val dataSource = if (startTime != null || duration != null) {
                    val sourceDurationUs: Long
                    val originUs: Long
                    try {
                        source.initialize()
                        sourceDurationUs = source.durationUs
                        originUs = firstSampleTimeUs(context, uri)
                    } catch (e: Exception) {
                        deinitializeQuietly(source)
                        result.error(channelName, "compressVideo error", e.message)
                        return
                    }
                    val range = exportRangeUs(startTime, duration, sourceDurationUs)
                    if (range == null) {
                        deinitializeQuietly(source)
                        result.error(channelName, "compressVideo error",
                            "startTime $startTime and duration $duration name no part of the " +
                                "${sourceDurationUs / 1_000_000.0} s of $path")
                        return
                    }
                    trimmedSource(source, range, originUs)
                } else {
                    source
                }


                val compress = PendingCompress(destPath, result)
                pending = compress
                compress.future = Transcoder.into(destPath)
                        .addDataSource(dataSource)
                        .setAudioTrackStrategy(audioTrackStrategy)
                        .setVideoTrackStrategy(videoTrackStrategy)
                        .setListener(object : TranscoderListener {
                            override fun onTranscodeProgress(progress: Double) {
                                if (!compress.answered) {
                                    channel.invokeMethod("updateProgress", progress * 100.00)
                                }
                            }
                            override fun onTranscodeCompleted(successCode: Int) {
                                if (pending === compress) pending = null
                                if (compress.answered) {
                                    // Already answered as cancelled: no output.
                                    File(destPath).delete()
                                    return
                                }
                                channel.invokeMethod("updateProgress", 100.00)
                                val json = try {
                                    Utility(channelName).getMediaInfoJson(context, destPath)
                                } catch (e: Exception) {
                                    File(destPath).delete()
                                    compress.answer { it.error(channelName, "compressVideo error", e.message) }
                                    return
                                }
                                json.put("isCancel", false)
                                compress.answer { it.success(json.toString()) }
                                if (deleteOrigin) {
                                    File(path).delete()
                                }
                            }

                            override fun onTranscodeCanceled() {
                                if (pending === compress) pending = null
                                // Nothing was compressed: no path, and the
                                // partial output is deleted.
                                File(destPath).delete()
                                compress.answer { it.success(cancelledJson()) }
                            }

                            override fun onTranscodeFailed(exception: Throwable) {
                                if (pending === compress) pending = null
                                File(destPath).delete()
                                compress.answer { it.error(channelName, "compressVideo error", exception.message) }
                            }
                        }).transcode()
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        init(binding.applicationContext, binding.binaryMessenger)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        _channel?.setMethodCallHandler(null)
        _context = null
        _channel = null
    }

    private fun init(context: Context, messenger: BinaryMessenger) {
        val channel = MethodChannel(messenger, channelName)
        channel.setMethodCallHandler(this)
        _context = context
        _channel = channel
    }

    private fun cancelledJson(): String = JSONObject().put("isCancel", true).toString()

    /** Releases [source]'s extractor; a failure while cleaning up changes no answer. */
    private fun deinitializeQuietly(source: DataSource) {
        try {
            source.deinitialize()
        } catch (e: Exception) {
            // Nothing to do: the compress already answers an error.
        }
    }

    /**
     * One compress: its output path and its result, answered exactly once
     * (the cancel and the engine's own callback can both try to answer).
     * Main thread only.
     */
    internal class PendingCompress(val destPath: String, private val result: MethodChannel.Result) {
        var future: Future<Void>? = null
        var answered = false
            private set

        fun answer(reply: (MethodChannel.Result) -> Unit) {
            if (answered) return
            answered = true
            reply(result)
        }
    }

    companion object {
        private const val TAG = "video_compress"
    }

}
