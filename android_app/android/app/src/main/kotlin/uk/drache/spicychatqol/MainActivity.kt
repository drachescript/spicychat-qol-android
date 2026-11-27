package uk.drache.spicychatqol

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Base64
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private val appInfoChannel = "uk.drache.spicychatqol/app_info"
    private val microphonePermissionRequestCode = 4021
    private var pendingMicrophonePermissionResult: MethodChannel.Result? = null
    // Native text export is verified by reading the written Storage Access
    // Framework document back before success is reported to Flutter.
    private val diagnosticExportRequestCode = 4718
    private var pendingDiagnosticExportResult: MethodChannel.Result? = null
    private var pendingDiagnosticExportBytes: ByteArray? = null
    // DS_ANDROID_V062_VERIFIED_EXPORT: one in-flight SAF document request at a time.
    private val verifiedExportRequestCode = 4719
    private var pendingVerifiedExportResult: MethodChannel.Result? = null
    private var pendingVerifiedExportFile: File? = null
    private var pendingVerifiedExportDigest: ByteArray? = null
    private var pendingVerifiedExportName = ""
    // DS_ANDROID_V063_EXPORT_WORKER: keep duplicate saves blocked until I/O finishes.
    @Volatile private var verifiedExportWriteInProgress = false


    // DS_ANDROID_STAGED_EXPORT_V2: Android may reclaim this Activity while SAF
    // owns the screen. Retain only an app-private file reference in saved state.
    // Never retry a write without a matching Activity result from the picker.
    private fun stagedExportFile(name: String?): File? {
        if (name == null || !name.matches(Regex("qol-export-[A-Za-z0-9_-]+\\.pending"))) return null
        val file = File(cacheDir, name)
        return if (file.isFile && file.canonicalFile.parentFile == cacheDir.canonicalFile &&
            file.length() in 1L..(24L * 1024 * 1024)) file else null
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        try {
            pendingVerifiedExportFile = stagedExportFile(savedInstanceState?.getString("qolExportStageV2"))
            pendingVerifiedExportName = savedInstanceState?.getString("qolExportNameV2").orEmpty()
            pendingVerifiedExportDigest = savedInstanceState?.getByteArray("qolExportDigestV2")
            if (pendingVerifiedExportDigest?.size != 32) pendingVerifiedExportFile = null
        } catch (_: Exception) { pendingVerifiedExportFile = null }
        super.onCreate(savedInstanceState)
    }

    override fun onSaveInstanceState(outState: android.os.Bundle) {
        pendingVerifiedExportFile?.let { outState.putString("qolExportStageV2", it.name) }
        outState.putString("qolExportNameV2", pendingVerifiedExportName)
        outState.putByteArray("qolExportDigestV2", pendingVerifiedExportDigest)
        super.onSaveInstanceState(outState)
    }

    private fun finishStagedExport(reply: MethodChannel.Result?, outcome: Map<String, Any>) {
        if (reply != null) {
            reply.success(outcome)
        } else {
            // The originating Flutter/JS request no longer exists. Do not mark
            // any QoL history exported or otherwise fabricate a bridge result.
            android.util.Log.i("QolNativeExport", "Restored picker result: verified=${outcome["verified"] == true}; bytes=${outcome["bytes"] ?: 0}")
            if (outcome["canceled"] != true) {
                android.widget.Toast.makeText(this,
                    if (outcome["verified"] == true) "Recovered export saved and verified."
                    else "Interrupted export was not verified. Please export again.",
                    android.widget.Toast.LENGTH_LONG).show()
            }
        }
    }

    // DS_ANDROID_031_RELIABILITY_V1: bounded native surface evidence, not a crash detector.
    private fun sampleWebViewSurface(redraw: Boolean, result: MethodChannel.Result) {
        val candidates = mutableListOf<android.webkit.WebView>()
        val pending = java.util.ArrayDeque<android.view.View>()
        pending.add(window.decorView)
        var visited = 0
        while (pending.isNotEmpty() && visited < 512) {
            val view = pending.removeFirst()
            visited++
            if (view is android.webkit.WebView && view.isAttachedToWindow &&
                view.isShown && view.windowVisibility == android.view.View.VISIBLE) {
                candidates.add(view)
            }
            if (view is android.view.ViewGroup) {
                for (i in 0 until view.childCount) pending.add(view.getChildAt(i))
            }
        }
        if (candidates.size != 1 || pending.isNotEmpty()) {
            result.success(mapOf("available" to false, "candidates" to candidates.size,
                "traversalLimited" to pending.isNotEmpty(), "redrawRequested" to false))
            return
        }
        val view = candidates.single()
        val rect = android.graphics.Rect()
        val visible = view.getGlobalVisibleRect(rect)
        val sample = mutableMapOf<String, Any>(
            "available" to true, "widthPx" to view.width, "heightPx" to view.height,
            "measuredWidthPx" to view.measuredWidth, "measuredHeightPx" to view.measuredHeight,
            "attached" to view.isAttachedToWindow, "shown" to view.isShown,
            "globalVisible" to visible, "visibleWidthPx" to rect.width(),
            "visibleHeightPx" to rect.height(), "windowVisibility" to view.windowVisibility,
            "hardwareAccelerated" to view.isHardwareAccelerated, "redrawRequested" to redraw)
        if (redraw) {
            view.requestLayout()
            view.invalidate()
        }
        // A visual-state callback indicates Chromium has reached a drawable state,
        // not that the compositor actually displayed pixels. Never recreate here.
        val handler = android.os.Handler(android.os.Looper.getMainLooper())
        var finished = false
        fun finish(state: String) {
            if (finished) return
            finished = true
            sample["visualState"] = state
            result.success(sample)
        }
        handler.postDelayed({ finish("timeout") }, 1600L)
        try {
            view.postVisualStateCallback(android.os.SystemClock.uptimeMillis(),
                object : android.webkit.WebView.VisualStateCallback() {
                    override fun onComplete(requestId: Long) {
                        finish(if (view.isAttachedToWindow) "callback" else "detached")
                    }
                })
        } catch (_: Exception) { finish("unavailable") }
    }

    @Suppress("DEPRECATION")
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            appInfoChannel,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "sampleWebViewSurface" -> {
                    try {
                        sampleWebViewSurface(call.argument<Boolean>("redraw") == true, result)
                    } catch (_: Exception) {
                        result.success(mapOf("available" to false, "reason" to "native-probe-failed"))
                    }
                }
                "getLorebookJobDirectory" -> {
                    result.success(File(noBackupFilesDir, "qol_lorebook_jobs_v1").path)
                }
                // DS_ANDROID_STORAGE_PRESSURE_V1: no traces or descriptions;
                // numeric exit details only, and only this app's main process.
                "getRecentAppExitReasons" -> {
                    try {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                            result.success(emptyList<Map<String, Any>>())
                        } else {
                            val manager = getSystemService(android.app.ActivityManager::class.java)
                            val exits = manager?.getHistoricalProcessExitReasons(packageName, 0, 8)
                                ?: emptyList()
                            val rows = exits.filter { it.processName == packageName }
                                .take(5).map { info ->
                                    mapOf("pid" to info.pid, "timestampMs" to info.timestamp,
                                        "reason" to info.reason, "status" to info.status,
                                        "importance" to info.importance, "pssKb" to info.pss,
                                        "rssKb" to info.rss)
                                }
                            result.success(rows)
                        }
                    } catch (_: Exception) {
                        result.success(emptyList<Map<String, Any>>())
                    }
                }

                "getAppInfo" -> {
                    try {
                        val packageInfo = packageManager.getPackageInfo(
                            packageName,
                            0,
                        )

                        val versionCode = if (
                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
                        ) {
                            packageInfo.longVersionCode
                        } else {
                            packageInfo.versionCode.toLong()
                        }

                        result.success(
                            mapOf(
                                "versionName" to (packageInfo.versionName ?: "unknown"),
                                "versionCode" to versionCode,
                            ),
                        )
                    } catch (error: Exception) {
                        result.error(
                            "APP_INFO_FAILED",
                            "Could not read installed package information.",
                            error.message,
                        )
                    }
                }

                "hasMicrophonePermission" -> {
                    result.success(hasMicrophonePermission())
                }

                "requestMicrophonePermission" -> {
                    if (hasMicrophonePermission()) {
                        result.success(true)
                        return@setMethodCallHandler
                    }

                    if (pendingMicrophonePermissionResult != null) {
                        result.error(
                            "MICROPHONE_PERMISSION_BUSY",
                            "A microphone permission request is already active.",
                            null,
                        )
                        return@setMethodCallHandler
                    }

                    pendingMicrophonePermissionResult = result
                    requestPermissions(
                        arrayOf(Manifest.permission.RECORD_AUDIO),
                        microphonePermissionRequestCode,
                    )
                }

                "exportDiagnosticLog" -> {
                    if (pendingDiagnosticExportResult != null) {
                        result.error("LOG_EXPORT_BUSY", "Another App Log export is in progress.", null)
                        return@setMethodCallHandler
                    }
                    val content = call.argument<String>("content").orEmpty()
                    val bytes = content.toByteArray(Charsets.UTF_8)
                    if (bytes.isEmpty() || bytes.size > 4 * 1024 * 1024) {
                        result.error("LOG_EXPORT_SIZE", "The App Log is empty or exceeds the 4 MB export limit.", bytes.size)
                        return@setMethodCallHandler
                    }
                    val suggested = call.argument<String>("filename").orEmpty()
                    val safeName = suggested
                        .replace(Regex("[^A-Za-z0-9._-]"), "_")
                        .take(140)
                        .let { if (it.isBlank()) "spicychat-qol-android-log.txt" else it }
                        .let { if (it.lowercase().endsWith(".txt")) it else "$it.txt" }
                    val documentIntent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TITLE, safeName)
                    }
                    pendingDiagnosticExportResult = result
                    pendingDiagnosticExportBytes = bytes
                    try {
                        startActivityForResult(documentIntent, diagnosticExportRequestCode)
                    } catch (error: Exception) {
                        pendingDiagnosticExportResult = null
                        pendingDiagnosticExportBytes = null
                        result.error("LOG_EXPORT_PICKER", "Could not open the Android document picker.", error.message)
                    }
                }

                "saveVerifiedFile" -> {
                    if (pendingVerifiedExportResult != null || pendingVerifiedExportFile != null || verifiedExportWriteInProgress || pendingDiagnosticExportResult != null) {
                        result.success(mapOf("ok" to false, "error" to "save-busy"))
                        return@setMethodCallHandler
                    }
                    try {
                        val encoded = call.argument<String>("base64").orEmpty()
                        // Limit IPC inflation and bound verification memory.
                        if (encoded.isEmpty() || encoded.length > 34 * 1024 * 1024) {
                            result.success(mapOf("ok" to false, "error" to "invalid-size", "bytes" to 0))
                            return@setMethodCallHandler
                        }
                        // The worker decodes and checks the actual size after picking.
                        val filename = call.argument<String>("filename").orEmpty()
                            .replace(Regex("[^A-Za-z0-9._ -]"), "_")
                            .trim().take(140)
                            .ifEmpty { "spicychat-qol-export.txt" }
                        val requestedMime = call.argument<String>("mimeType").orEmpty()
                            .substringBefore(';').trim()
                        val mime = if (requestedMime.matches(Regex("^[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+$")))
                            requestedMime else "application/octet-stream"
                        val documentIntent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = mime
                            putExtra(Intent.EXTRA_TITLE, filename)
                        }
                        // Decode once on a worker and release the large base64
                        // string before handing the foreground to the picker.
                        verifiedExportWriteInProgress = true
                        try {
                            Thread({
                                var staged: File? = null
                                try {
                                    // Only old, app-owned staging files; no user downloads.
                                    val cutoff = System.currentTimeMillis() - 24L * 60 * 60 * 1000
                                    cacheDir.listFiles()?.filter {
                                        it.name.matches(Regex("qol-export-[A-Za-z0-9_-]+\\.pending")) &&
                                            it.lastModified() < cutoff
                                    }?.forEach { it.delete() }
                                    val file = File.createTempFile("qol-export-", ".pending", cacheDir)
                                    staged = file
                                    val bytes = Base64.decode(encoded, Base64.DEFAULT)
                                    if (bytes.isEmpty() || bytes.size > 24 * 1024 * 1024) {
                                        throw java.io.IOException("Invalid export size")
                                    }
                                    val originalDigest = MessageDigest.getInstance("SHA-256").digest(bytes)
                                    file.outputStream().use { output ->
                                        output.write(bytes)
                                        output.fd.sync()
                                    }
                                    runOnUiThread {
                                        verifiedExportWriteInProgress = false
                                        if (isFinishing || isDestroyed) {
                                            file.delete()
                                            result.success(mapOf("ok" to false, "error" to "activity-closed"))
                                        } else {
                                            pendingVerifiedExportFile = file
                                            pendingVerifiedExportDigest = originalDigest
                                            pendingVerifiedExportName = filename
                                            pendingVerifiedExportResult = result
                                            try {
                                                startActivityForResult(documentIntent, verifiedExportRequestCode)
                                            } catch (_: Exception) {
                                                pendingVerifiedExportResult = null
                                                pendingVerifiedExportFile = null
                                                pendingVerifiedExportDigest = null
                                                pendingVerifiedExportName = ""
                                                file.delete()
                                                result.success(mapOf("ok" to false, "error" to "picker-failed"))
                                            }
                                        }
                                    }
                                } catch (_: Exception) {
                                    staged?.delete()
                                    runOnUiThread {
                                        verifiedExportWriteInProgress = false
                                        result.success(mapOf("ok" to false, "error" to "stage-failed"))
                                    }
                                }
                            }, "qol-stage-export").start()
                        } catch (_: Exception) {
                            verifiedExportWriteInProgress = false
                            result.success(mapOf("ok" to false, "error" to "stage-worker-failed"))
                        }
                    } catch (error: Exception) {
                        result.success(mapOf("ok" to false, "error" to "invalid-payload"))
                    }
                }

                "installApk" -> {
                    try {
                        val path = call.argument<String>("path")?.trim().orEmpty()
                        val expectedSha = call.argument<String>("sha256")
                            ?.trim()
                            ?.lowercase()
                            ?.removePrefix("sha256:")
                            .orEmpty()

                        if (path.isEmpty()) {
                            result.error(
                                "APK_PATH_MISSING",
                                "The downloaded update APK path was missing.",
                                null,
                            )
                            return@setMethodCallHandler
                        }

                        val apk = File(path).canonicalFile
                        val cacheRoot = cacheDir.canonicalFile

                        if (
                            !apk.path.startsWith(cacheRoot.path + File.separator) ||
                            !apk.name.lowercase().endsWith(".apk") ||
                            !apk.exists() ||
                            apk.length() < 1024 * 1024
                        ) {
                            result.error(
                                "APK_INVALID",
                                "The downloaded update APK is missing or outside app cache.",
                                apk.path,
                            )
                            return@setMethodCallHandler
                        }

                        if (expectedSha.matches(Regex("^[0-9a-f]{64}$"))) {
                            val actualSha = sha256(apk)
                            if (!actualSha.equals(expectedSha, ignoreCase = true)) {
                                result.error(
                                    "APK_CHECKSUM_MISMATCH",
                                    "The downloaded APK checksum did not match the release.",
                                    "expected=$expectedSha actual=$actualSha",
                                )
                                return@setMethodCallHandler
                            }
                        }

                        if (
                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            !packageManager.canRequestPackageInstalls()
                        ) {
                            val permissionIntent = Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName"),
                            )
                            startActivity(permissionIntent)
                            result.success(
                                mapOf(
                                    "ok" to false,
                                    "permissionRequired" to true,
                                ),
                            )
                            return@setMethodCallHandler
                        }

                        val apkUri = FileProvider.getUriForFile(
                            this,
                            "$packageName.update.fileprovider",
                            apk,
                        )

                        val installIntent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(
                                apkUri,
                                "application/vnd.android.package-archive",
                            )
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }

                        startActivity(installIntent)

                        result.success(
                            mapOf(
                                "ok" to true,
                                "permissionRequired" to false,
                            ),
                        )
                    } catch (error: Exception) {
                        result.error(
                            "APK_INSTALL_FAILED",
                            "Could not open the Android package installer.",
                            error.message,
                        )
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == verifiedExportRequestCode) {
            val reply = pendingVerifiedExportResult
            val staged = pendingVerifiedExportFile
            val originalDigest = pendingVerifiedExportDigest
            val name = pendingVerifiedExportName
            pendingVerifiedExportResult = null
            pendingVerifiedExportFile = null
            pendingVerifiedExportDigest = null
            pendingVerifiedExportName = ""
            if (reply == null && staged == null) return
            if (resultCode != RESULT_OK || data?.data == null) {
                staged?.delete()
                finishStagedExport(reply, mapOf("ok" to false, "canceled" to true, "bytes" to 0))
                return
            }
            if (staged == null || originalDigest == null || originalDigest.size != 32 || !staged.isFile || staged.length() !in 1L..(24L * 1024 * 1024)) {
                staged?.delete()
                finishStagedExport(reply, mapOf("ok" to false, "error" to "missing-data", "bytes" to 0))
                return
            }
            // DS_ANDROID_V063_EXPORT_WORKER: SAF I/O and verification run off
            // the Android UI thread; reply only after readback confirmation.
            val uri = data.data!!
            verifiedExportWriteInProgress = true
            try {
                Thread({
                    val outcome: Map<String, Any> = try {
                        val expectedSize = staged.length().toInt()
                        val expectedDigest = MessageDigest.getInstance("SHA-256")
                        contentResolver.openOutputStream(uri, "wt")?.use { output ->
                            staged.inputStream().use { input ->
                                val buffer = ByteArray(65536)
                                var sent = 0
                                while (true) {
                                    val n = input.read(buffer)
                                    if (n < 0) break
                                    if (n == 0) continue
                                    sent += n
                                    if (sent > expectedSize) throw java.io.IOException("Staged file changed")
                                    expectedDigest.update(buffer, 0, n)
                                    output.write(buffer, 0, n)
                                }
                                if (sent != expectedSize) throw java.io.IOException("Staged file changed")
                            }
                            output.flush()
                        } ?: throw java.io.IOException("Document provider refused output stream")
                        val digest = MessageDigest.getInstance("SHA-256")
                        var writtenBytes = 0
                        contentResolver.openInputStream(uri)?.use { input ->
                            val buffer = ByteArray(65536)
                            while (true) {
                                val n = input.read(buffer)
                                if (n < 0) break
                                if (n == 0) continue
                                writtenBytes += n
                                if (writtenBytes > expectedSize) break
                                digest.update(buffer, 0, n)
                            }
                        } ?: throw java.io.IOException("Document provider refused readback")
                        val verified = writtenBytes == expectedSize &&
                            MessageDigest.isEqual(originalDigest, expectedDigest.digest()) &&
                            MessageDigest.isEqual(
                                originalDigest,
                                digest.digest(),
                            )
                        if (verified) {
                            // DS_ANDROID_V066_VERIFIED_RESULT: only successful
                            // SHA-256 readback may produce a nonzero byte report.
                            mapOf("ok" to true, "success" to true, "verified" to true,
                                "bytes" to writtenBytes,
                                "bytesWritten" to writtenBytes,
                                "savedBytes" to writtenBytes,
                                "fileSize" to writtenBytes,
                                "name" to name, "filename" to name,
                                "uri" to uri.toString())
                        } else {
                            mapOf("ok" to false, "error" to "verification-mismatch",
                                "bytes" to writtenBytes, "expectedBytes" to expectedSize)
                        }
                    } catch (_: Exception) {
                        mapOf("ok" to false, "error" to "write-or-readback-failed", "bytes" to 0)
                    }
                    staged.delete()
                    runOnUiThread {
                        verifiedExportWriteInProgress = false
                        finishStagedExport(reply, outcome)
                    }
                }, "qol-verified-file-export").start()
            } catch (_: Exception) {
                staged.delete()
                verifiedExportWriteInProgress = false
                finishStagedExport(reply, mapOf("ok" to false, "error" to "export-worker-failed", "bytes" to 0))
            }
            return
        }
        if (requestCode != diagnosticExportRequestCode) return

        val reply = pendingDiagnosticExportResult ?: return
        val expected = pendingDiagnosticExportBytes
        pendingDiagnosticExportResult = null
        pendingDiagnosticExportBytes = null

        if (resultCode != RESULT_OK || data?.data == null) {
            reply.success(mapOf("ok" to false, "cancelled" to true))
            return
        }
        if (expected == null || expected.isEmpty()) {
            reply.error("LOG_EXPORT_EMPTY", "The App Log content was unavailable.", null)
            return
        }

        try {
            val uri = data.data!!
            val output = contentResolver.openOutputStream(uri, "wt")
                ?: throw java.io.IOException("The document provider refused the output stream.")
            output.use {
                it.write(expected)
                it.flush()
            }
            val written = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                ?: throw java.io.IOException("The exported log cannot be read back for verification.")
            if (!expected.contentEquals(written)) {
                reply.error(
                    "LOG_EXPORT_VERIFY",
                    "The exported log did not match the original content. Use Copy App Log instead.",
                    "expected=${expected.size}, actual=${written.size}",
                )
                return
            }
            reply.success(mapOf("ok" to true, "verified" to true, "bytes" to written.size))
        } catch (error: Exception) {
            reply.error("LOG_EXPORT_FAILED", "Could not write and verify the App Log.", error.message)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != microphonePermissionRequestCode) return

        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED

        pendingMicrophonePermissionResult?.success(granted)
        pendingMicrophonePermissionResult = null
    }

    private fun hasMicrophonePermission(): Boolean =
        checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count <= 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { byte ->
            "%02x".format(byte)
        }
    }
}
