package com.muse2.line_call

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val reader = VideoReaderSession()

    override fun onCreate(savedInstanceState: Bundle?) {
        // Edge-to-edge: opt the window into drawing under the system bars on
        // every Android version. Equivalent to enableEdgeToEdge() but uses
        // androidx.core (always on the classpath via Flutter) instead of
        // androidx.activity, which avoids the version-conflict receiver
        // mismatch with FlutterActivity's transitive ComponentActivity.
        // Lint's EdgeToEdge check accepts this call as the canonical opt-in.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Native sequential frame reader for the ball-tracking scan and the
        // challenge review clips — same "line_call/video" channel + method
        // names the Dart side uses on every platform. Only the reader
        // methods are wired (scrub stills still go through video_thumbnail).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "line_call/video").setMethodCallHandler { call, result ->
            when (call.method) {
                "openReader" -> reader.open(
                    call.argument<String>("path") ?: "",
                    (call.argument<Number>("startMs") ?: 0).toDouble(),
                    (call.argument<Number>("maxWidth") ?: 1280).toInt(),
                    (call.argument<Number>("minIntervalMs") ?: 30).toDouble(),
                    result)
                "nextFrame" -> reader.next(result)
                "closeReader" -> { reader.close(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        reader.close()
        super.onDestroy()
    }
}

/**
 * Sequential video frame reader. Reuses ONE [MediaMetadataRetriever] across the
 * whole scan and pulls frames by index (API 28+) — far faster than the
 * per-frame video_thumbnail path, which re-opens the file and seeks every call.
 * Returns at most one frame per minIntervalMs of video time. Android twin of the
 * iOS/macOS AVAssetReader sessions. Work runs on a single-thread executor;
 * results are posted back to the platform thread. open() returns false on
 * API < 28 or any error, so the Dart caller falls back to grabVideoFrame.
 */
class VideoReaderSession {
    private val exec = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var retriever: MediaMetadataRetriever? = null
    private var maxWidth = 1280
    private var index = 0
    private var step = 1
    private var frameCount = 0
    private var frameMs = 0.0 // video time per frame index (ms) — for exact centring

    fun open(path: String, startMs: Double, maxWidth: Int, minIntervalMs: Double,
             result: MethodChannel.Result) {
        exec.execute {
            closeSync()
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) { // API 28
                main.post { result.success(false) }
                return@execute
            }
            try {
                val r = MediaMetadataRetriever()
                r.setDataSource(path)
                val count = r.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)
                    ?.toIntOrNull() ?: 0
                val durMs = r.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toDoubleOrNull() ?: 0.0
                if (count <= 0 || durMs <= 0.0) {
                    r.release()
                    main.post { result.success(false) }
                    return@execute
                }
                val frameMs = durMs / count
                this.maxWidth = maxWidth
                this.frameMs = frameMs
                this.frameCount = count
                this.step = maxOf(1, Math.round(minIntervalMs / frameMs).toInt())
                this.index = maxOf(0, Math.round(startMs / frameMs).toInt())
                this.retriever = r
                main.post { result.success(true) }
            } catch (e: Exception) {
                main.post { result.success(false) }
            }
        }
    }

    fun next(result: MethodChannel.Result) {
        exec.execute {
            val r = retriever
            if (r == null || index >= frameCount) {
                main.post { result.success(null) }
                return@execute
            }
            try {
                val frameIndex = index
                val bmp = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
                    r.getFrameAtIndex(frameIndex) else null
                index += step
                if (bmp == null) {
                    main.post { result.success(null) }
                    return@execute
                }
                var scaled = scale(bmp)
                // RAW RGBA bytes (+ dims): ARGB_8888 copyPixelsToBuffer yields
                // R,G,B,A byte order, which the Dart detector reads directly.
                if (scaled.config != Bitmap.Config.ARGB_8888) {
                    val c = scaled.copy(Bitmap.Config.ARGB_8888, false)
                    if (scaled !== bmp) scaled.recycle()
                    scaled = c
                }
                val bw = scaled.width
                val bh = scaled.height
                val buf = ByteBuffer.allocate(bw * bh * 4)
                scaled.copyPixelsToBuffer(buf)
                if (scaled !== bmp) scaled.recycle()
                bmp.recycle()
                val map = HashMap<String, Any>()
                map["width"] = bw
                map["height"] = bh
                map["bytes"] = buf.array()
                map["ms"] = frameIndex * frameMs
                main.post { result.success(map) }
            } catch (e: Exception) {
                main.post { result.success(null) }
            }
        }
    }

    fun close() { exec.execute { closeSync() } }

    private fun closeSync() {
        try { retriever?.release() } catch (e: Exception) {}
        retriever = null
        index = 0
        frameCount = 0
    }

    private fun scale(bmp: Bitmap): Bitmap {
        val longer = maxOf(bmp.width, bmp.height)
        if (maxWidth <= 0 || longer <= maxWidth) return bmp
        val s = maxWidth.toDouble() / longer
        return Bitmap.createScaledBitmap(
            bmp, Math.round(bmp.width * s).toInt(),
            Math.round(bmp.height * s).toInt(), true)
    }
}
