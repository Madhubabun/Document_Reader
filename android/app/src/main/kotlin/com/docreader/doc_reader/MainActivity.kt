package com.docreader.doc_reader

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Receives files from other apps ("Open with" and "Share") and hands them
 * to Flutter as copies in the app's cache, since the other app's
 * permission to read them ends with this activity.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private val pending = mutableListOf<Map<String, String>>()
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "doc_reader/incoming").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "take" -> {
                        result.success(pending.toList())
                        pending.clear()
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A fresh start (not a restore, not reopened from recents) may carry files.
        if (savedInstanceState == null && (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) == 0) {
            worker.execute { File(cacheDir, "incoming").deleteRecursively() }
            receive(intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        receive(intent)
    }

    override fun onDestroy() {
        channel?.setMethodCallHandler(null)
        worker.shutdown()
        super.onDestroy()
    }

    private fun receive(intent: Intent?) {
        val uris = urisOf(intent ?: return)
        if (uris.isEmpty()) return
        // The type the sending app declared, used when the provider gives none.
        val declared = intent.type?.takeIf { !it.contains('*') }
        worker.execute {
            // A file that can't be copied still goes to Flutter, with no
            // path, so the user hears that it could not be opened.
            val copied = uris.map { copy(it, declared) ?: mapOf("path" to "", "name" to "", "type" to "") }
            main.post {
                pending.addAll(copied)
                channel?.invokeMethod("available", null)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun urisOf(intent: Intent): List<Uri> = when (intent.action) {
        Intent.ACTION_VIEW -> listOfNotNull(intent.data)
        Intent.ACTION_SEND -> listOfNotNull(
            if (Build.VERSION.SDK_INT >= 34) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        )
        Intent.ACTION_SEND_MULTIPLE -> (
            if (Build.VERSION.SDK_INT >= 34) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
        )?.filterNotNull() ?: emptyList()
        else -> emptyList()
    }.filter { it.scheme == "content" }

    /** Copies [uri] into the cache; returns its path, name and type, or null if it can't be read. */
    private fun copy(uri: Uri, declared: String?): Map<String, String>? = try {
        val type = contentResolver.getType(uri) ?: declared ?: ""
        var name = displayName(uri) ?: uri.lastPathSegment?.substringAfterLast('/') ?: "file"
        name = name.replace(Regex("[\\\\/:*?\"<>|\\x00-\\x1F]"), "-").trim().trimStart('.').ifEmpty { "file" }
        if (!name.contains('.')) {
            MimeTypeMap.getSingleton().getExtensionFromMimeType(type)?.let { name = "$name.$it" }
        }
        val dir = File(cacheDir, "incoming/${System.nanoTime()}").apply { mkdirs() }
        val target = File(dir, name)
        val input = contentResolver.openInputStream(uri) ?: throw IllegalStateException("no stream")
        input.use { source -> target.outputStream().use { source.copyTo(it) } }
        mapOf("path" to target.absolutePath, "name" to name, "type" to type)
    } catch (e: Exception) {
        null
    }

    private fun displayName(uri: Uri): String? = try {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst() && !it.isNull(0)) it.getString(0) else null
        }
    } catch (e: Exception) {
        null
    }
}
