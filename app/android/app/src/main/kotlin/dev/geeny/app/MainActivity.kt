package dev.geeny.app

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

/**
 * Android side of import.
 *
 * Boya OS has no import API, but it can share and export files. Registering Geeny
 * for ACTION_SEND/ACTION_VIEW means "Share → Geeny" from that app lands here: the
 * content URI is copied into the app cache and Dart takes over. The system picker
 * is exposed the same way for a file that was exported to Downloads instead.
 */
class MainActivity : FlutterActivity() {
    private companion object {
        const val CHANNEL = "dev.geeny.app/share"
        const val PICK_REQUEST = 0x1E6E
    }

    private var channel: MethodChannel? = null
    private var pendingShare: Map<String, Any?>? = null
    private var pendingPick: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) pendingShare = readShare(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = methodChannel
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "initial" -> {
                    val shared = pendingShare
                    pendingShare = null
                    result.success(shared)
                }
                "pick" -> {
                    if (pendingPick != null) {
                        result.error("busy", "a picker is already open", null)
                    } else {
                        pendingPick = result
                        launchPicker()
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val shared = readShare(intent) ?: return
        val methodChannel = channel
        if (methodChannel != null) methodChannel.invokeMethod("shared", shared) else pendingShare = shared
    }

    private fun launchPicker() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf(
                    "audio/*",
                    "application/json",
                    "text/plain",
                    "text/markdown",
                    "application/x-subrip",
                ),
            )
        }
        try {
            startActivityForResult(intent, PICK_REQUEST)
        } catch (e: Exception) {
            pendingPick?.error("picker", e.message ?: "no file picker available", null)
            pendingPick = null
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_REQUEST) return
        val result = pendingPick ?: return
        pendingPick = null
        val uri = if (resultCode == RESULT_OK) data?.data else null
        if (uri == null) {
            result.success(null)
            return
        }
        result.success(copyToCache(uri, data?.type))
    }

    override fun onDestroy() {
        pendingPick?.success(null)
        pendingPick = null
        super.onDestroy()
    }

    /** Share sheet or "open with": EXTRA_STREAM (or the data URI, or plain text). */
    private fun readShare(intent: Intent?): Map<String, Any?>? {
        if (intent == null) return null
        val action = intent.action ?: return null
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_VIEW) return null
        val uri: Uri? = if (action == Intent.ACTION_SEND) {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        } else {
            intent.data
        }
        if (uri == null) {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            if (text.isNullOrBlank()) return null
            return writeBytes("shared-${System.currentTimeMillis()}.txt", text.toByteArray(), "text/plain")
        }
        return copyToCache(uri, intent.type)
    }

    private fun copyToCache(uri: Uri, mimeType: String?): Map<String, Any?>? {
        return try {
            var name = displayName(uri) ?: "shared-${System.currentTimeMillis()}"
            val mime = mimeType ?: contentResolver.getType(uri) ?: ""
            if (!name.contains('.')) name = "$name.${extensionFor(mime)}"
            val safe = name.replace(Regex("[^A-Za-z0-9._ -]"), "_")
            val target = File(File(cacheDir, "import"), "${UUID.randomUUID()}-$safe")
            target.parentFile?.mkdirs()
            var copied = 0L
            contentResolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read <= 0) break
                        output.write(buffer, 0, read)
                        copied += read
                    }
                }
            } ?: return null
            mapOf("path" to target.absolutePath, "name" to name, "mime" to mime, "size" to copied)
        } catch (e: Exception) {
            null
        }
    }

    private fun writeBytes(name: String, bytes: ByteArray, mime: String): Map<String, Any?>? {
        return try {
            val target = File(File(cacheDir, "import"), "${UUID.randomUUID()}-$name")
            target.parentFile?.mkdirs()
            target.writeBytes(bytes)
            mapOf("path" to target.absolutePath, "name" to name, "mime" to mime, "size" to bytes.size)
        } catch (e: Exception) {
            null
        }
    }

    private fun displayName(uri: Uri): String? {
        return try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val index = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                if (index >= 0 && cursor.moveToFirst()) cursor.getString(index) else null
            }
        } catch (e: Exception) {
            uri.lastPathSegment
        }
    }

    private fun extensionFor(mime: String): String = when {
        mime.contains("ogg") -> "ogg"
        mime.contains("mpeg") -> "mp3"
        mime.contains("mp4") || mime.contains("m4a") -> "m4a"
        mime.contains("wav") -> "wav"
        mime.contains("flac") -> "flac"
        mime.contains("json") -> "json"
        mime.contains("subrip") -> "srt"
        mime.contains("markdown") -> "md"
        mime.startsWith("text/") -> "txt"
        else -> "bin"
    }
}
