package ai.bb.bb_mobile

import android.Manifest
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : FlutterActivity() {
    private val channelName = "bb/media_clipboard"
    private val maxClipboardBytes = 32 * 1024 * 1024

    private data class PendingGallerySave(
        val path: String,
        val filename: String,
        val mimeType: String,
        val isVideo: Boolean,
    )

    private var pendingGallerySave: PendingGallerySave? = null
    private var pendingGalleryResult: MethodChannel.Result? = null

    private companion object {
        const val GALLERY_PERMISSION_REQUEST = 4711
    }

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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bb/media_gallery")
            .setMethodCallHandler { call, result ->
                if (call.method != "saveToGallery") {
                    if (call.method == "saveToPhotos") {
                        // Reserved for the iOS Photos implementation; this
                        // project has no iOS runner and must not claim it works.
                        result.error(
                            "unsupported",
                            "Photos save is not part of this build",
                            null,
                        )
                    } else {
                        result.notImplemented()
                    }
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                val filename = call.argument<String>("filename")
                val mimeType = call.argument<String>("mime_type") ?: "application/octet-stream"
                val isVideo = call.argument<Boolean>("is_video") ?: false
                if (path.isNullOrBlank() || filename.isNullOrBlank()) {
                    result.error("save_failed", "missing path or filename", null)
                    return@setMethodCallHandler
                }
                if (!File(path).isFile) {
                    result.error("file_missing", "staged media is gone", null)
                    return@setMethodCallHandler
                }
                if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.P &&
                    checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
                    PackageManager.PERMISSION_GRANTED
                ) {
                    if (pendingGalleryResult != null) {
                        result.error("busy", "another gallery save is pending", null)
                        return@setMethodCallHandler
                    }
                    pendingGallerySave = PendingGallerySave(path, filename, mimeType, isVideo)
                    pendingGalleryResult = result
                    requestPermissions(
                        arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                        GALLERY_PERMISSION_REQUEST,
                    )
                    return@setMethodCallHandler
                }
                try {
                    result.success(saveToGallery(path, filename, mimeType, isVideo))
                } catch (error: Exception) {
                    result.error("save_failed", error.message ?: "save failed", null)
                }
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != GALLERY_PERMISSION_REQUEST) {
            return
        }
        val pending = pendingGallerySave
        val result = pendingGalleryResult
        pendingGallerySave = null
        pendingGalleryResult = null
        if (pending == null || result == null) {
            return
        }
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            result.error("permission_denied", "gallery write permission denied", null)
            return
        }
        try {
            result.success(
                saveToGallery(
                    pending.path,
                    pending.filename,
                    pending.mimeType,
                    pending.isVideo,
                ),
            )
        } catch (error: Exception) {
            result.error("save_failed", error.message ?: "save failed", null)
        }
    }

    /// Inserts the staged file into MediaStore. Fails loudly and removes a
    /// partially written row instead of leaving a broken gallery item.
    private fun saveToGallery(
        path: String,
        originalName: String,
        mimeType: String,
        isVideo: Boolean,
    ): String {
        val displayName = galleryFileName(originalName, mimeType)
        val resolver = contentResolver
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // Pre-Q MediaStore requires a real public DATA path. The write
            // permission was granted above; the row is inserted after the copy.
            val base = Environment.getExternalStoragePublicDirectory(
                if (isVideo) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES,
            )
            val album = File(base, "BB")
            if (!album.exists() && !album.mkdirs()) {
                throw IllegalStateException("cannot create gallery album")
            }
            var target = File(album, displayName)
            var suffix = 1
            while (target.exists()) {
                target = File(album, addSuffix(displayName, suffix))
                suffix += 1
            }
            File(path).copyTo(target, overwrite = false)
            val collection = if (isVideo) {
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            } else {
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            }
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DATA, target.absolutePath)
                put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                put(MediaStore.MediaColumns.SIZE, target.length())
            }
            if (resolver.insert(collection, values) == null) {
                target.delete()
                throw IllegalStateException("MediaStore insert failed")
            }
            val relative = if (isVideo) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES
            return "$relative/BB/${target.name}"
        }
        val collection = if (isVideo) {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }
        val relativeDir = if (isVideo) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativeDir + "/BB")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri: Uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("MediaStore insert failed")
        try {
            val output = resolver.openOutputStream(uri)
                ?: throw IllegalStateException("cannot open gallery stream")
            output.use { stream ->
                File(path).inputStream().use { input -> input.copyTo(stream) }
            }
            val published = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }
            resolver.update(uri, published, null, null)
            return "$relativeDir/BB/$displayName"
        } catch (error: Exception) {
            runCatching { resolver.delete(uri, null, null) }
            throw error
        }
    }

    private fun addSuffix(name: String, suffix: Int): String {
        val dot = name.lastIndexOf('.')
        return if (dot > 0) {
            "${name.substring(0, dot)} ($suffix)${name.substring(dot)}"
        } else {
            "$name ($suffix)"
        }
    }

    /// Stable gallery name: `bb_<timestamp>_<sanitized original>.<ext>`.
    private fun galleryFileName(originalName: String, mimeType: String): String {
        val cleaned = originalName
            .replace(Regex("[\\\\/:*?\"<>|\\u0000-\\u001F]"), "_")
            .trim()
            .ifEmpty { "media" }
        val stamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        val dot = cleaned.lastIndexOf('.')
        val hasExtension = dot > 0 && dot < cleaned.length - 1
        val stem = (if (hasExtension) cleaned.substring(0, dot) else cleaned).take(80)
        val extension = if (hasExtension) {
            cleaned.substring(dot)
        } else {
            ".${extensionForMime(mimeType)}"
        }
        return "bb_${stamp}_$stem$extension"
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
