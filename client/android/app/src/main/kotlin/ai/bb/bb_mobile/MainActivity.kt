package ai.bb.bb_mobile

import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    private val channelName = "bb/media_clipboard"
    private val maxClipboardBytes = 32 * 1024 * 1024

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method != "readClipboardMedia") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    result.success(readClipboardMedia())
                } catch (error: Exception) {
                    result.error("clipboard_error", error.message, null)
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bb/video_cover")
            .setMethodCallHandler { call, result ->
                if (call.method != "extractVideoCover") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                if (path.isNullOrBlank()) {
                    result.error("video_cover_error", "missing path", null)
                    return@setMethodCallHandler
                }
                try {
                    result.success(extractVideoCover(path))
                } catch (error: Exception) {
                    result.error("video_cover_error", error.message ?: "cover failed", null)
                }
            }
    }

    /** Project-owned frame extraction, so no third-party Gradle plugin is needed. */
    private fun extractVideoCover(path: String): ByteArray? {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val frame = retriever.getFrameAtTime(
                0,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            ) ?: return null
            val maxWidth = 720
            val scaled = if (frame.width > maxWidth) {
                Bitmap.createScaledBitmap(
                    frame,
                    maxWidth,
                    (frame.height * maxWidth) / frame.width,
                    true,
                )
            } else {
                frame
            }
            val output = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.PNG, 100, output)
            if (scaled !== frame) {
                scaled.recycle()
            }
            frame.recycle()
            return output.toByteArray()
        } finally {
            retriever.release()
        }
    }

    private fun readClipboardMedia(): Map<String, Any>? {
        val manager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = manager.primaryClip ?: return null
        for (index in 0 until clip.itemCount) {
            val item = clip.getItemAt(index)
            val text = item.text?.toString()?.trim()
            var uri: Uri? = item.uri
            if (uri == null && !text.isNullOrEmpty()) {
                uri = runCatching { Uri.parse(text) }.getOrNull()
            }
            if (uri == null) {
                continue
            }
            val scheme = uri.scheme ?: continue
            if (scheme != "content" && scheme != "file") {
                continue
            }
            val mime = contentResolver.getType(uri) ?: guessMime(uri) ?: continue
            if (!mime.startsWith("image/") && !mime.startsWith("video/")) {
                continue
            }
            val bytes = contentResolver.openInputStream(uri)?.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(64 * 1024)
                var total = 0
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) {
                        break
                    }
                    total += read
                    if (total > maxClipboardBytes) {
                        throw IllegalStateException("clipboard media exceeds 32 MiB")
                    }
                    output.write(buffer, 0, read)
                }
                output.toByteArray()
            }
            if (bytes == null || bytes.isEmpty()) {
                continue
            }
            val filename = queryName(uri)
                ?: "clipboard-${System.currentTimeMillis()}.${extensionForMime(mime)}"
            return mapOf(
                "data" to bytes,
                "mime_type" to mime,
                "filename" to filename,
            )
        }
        return null
    }

    private fun queryName(uri: Uri): String? {
        if (uri.scheme == "file") {
            return uri.lastPathSegment
        }
        return contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (column >= 0) cursor.getString(column) else null
            } else {
                null
            }
        }
    }

    private fun guessMime(uri: Uri): String? {
        return when (uri.lastPathSegment?.substringAfterLast('.', "")?.lowercase()) {
            "png" -> "image/png"
            "jpg", "jpeg" -> "image/jpeg"
            "webp" -> "image/webp"
            "mp4" -> "video/mp4"
            "webm" -> "video/webm"
            else -> null
        }
    }

    private fun extensionForMime(mime: String): String {
        return when (mime) {
            "image/png" -> "png"
            "image/jpeg" -> "jpg"
            "image/webp" -> "webp"
            "video/mp4" -> "mp4"
            "video/webm" -> "webm"
            else -> "bin"
        }
    }
}
