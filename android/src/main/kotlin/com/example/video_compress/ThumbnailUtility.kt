package com.example.video_compress

import android.content.Context
import android.graphics.Bitmap
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException

/**
 * Every thumbnail request answers exactly once: a frame that cannot be read,
 * or a file that cannot be written, answers an error.
 */
class ThumbnailUtility(private val channelName: String) {
    private val utility = Utility(channelName)

    fun getByteThumbnail(path: String, quality: Int, positionMs: Long, result: MethodChannel.Result) {
        val bmp = utility.getBitmap(path, positionMs)
            ?: return result.error(channelName, "getByteThumbnail error", "Could not read a frame of $path")

        val stream = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, quality, stream)
        val byteArray = stream.toByteArray()
        bmp.recycle()
        result.success(byteArray)
    }

    fun getFileThumbnail(context: Context, path: String, quality: Int, positionMs: Long,
                             result: MethodChannel.Result) {
        val bmp = utility.getBitmap(path, positionMs)
            ?: return result.error(channelName, "getFileThumbnail error", "Could not read a frame of $path")

        val dir = context.getExternalFilesDir("video_compress")

        if (dir != null && !dir.exists()) dir.mkdirs()

        val file = File(dir, File(path).nameWithoutExtension + ".jpg")
        utility.deleteFile(file)

        val stream = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, quality, stream)
        val byteArray = stream.toByteArray()
        bmp.recycle()

        try {
            file.createNewFile()
            file.writeBytes(byteArray)
        } catch (e: IOException) {
            return result.error(channelName, "getFileThumbnail error", e.message)
        }

        result.success(file.absolutePath)
    }
}
