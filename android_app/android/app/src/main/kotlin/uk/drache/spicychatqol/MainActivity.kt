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
    private var pendingVerifiedExportBytes: ByteArray? = null
    private var pendingVerifiedExportName = ""


    @Suppress("DEPRECATION")
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            appInfoChannel,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
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
                    if (pendingVerifiedExportResult != null || pendingDiagnosticExportResult != null) {
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
                        val bytes = Base64.decode(encoded, Base64.DEFAULT)
                        if (bytes.isEmpty() || bytes.size > 24 * 1024 * 1024) {
                            result.success(mapOf("ok" to false, "error" to "invalid-size", "bytes" to 0))
                            return@setMethodCallHandler
                        }
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
                        pendingVerifiedExportBytes = bytes
                        pendingVerifiedExportName = filename
                        pendingVerifiedExportResult = result
                        try {
                            startActivityForResult(documentIntent, verifiedExportRequestCode)
                        } catch (error: Exception) {
                            pendingVerifiedExportResult = null
                            pendingVerifiedExportBytes = null
                            pendingVerifiedExportName = ""
                            result.success(mapOf("ok" to false, "error" to "picker-failed"))
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
            val reply = pendingVerifiedExportResult ?: return
            val expected = pendingVerifiedExportBytes
            val name = pendingVerifiedExportName
            pendingVerifiedExportResult = null
            pendingVerifiedExportBytes = null
            pendingVerifiedExportName = ""
            if (resultCode != RESULT_OK || data?.data == null) {
                reply.success(mapOf("ok" to false, "canceled" to true, "bytes" to 0))
                return
            }
            if (expected == null || expected.isEmpty()) {
                reply.success(mapOf("ok" to false, "error" to "missing-data", "bytes" to 0))
                return
            }
            try {
                val uri = data.data!!
                val output = contentResolver.openOutputStream(uri, "wt")
                    ?: throw java.io.IOException("Document provider refused output stream")
                output.use { it.write(expected); it.flush() }
                val actual = contentResolver.openInputStream(uri)?.use { input ->
                    val bytes = java.io.ByteArrayOutputStream()
                    val chunk = ByteArray(65536)
                    while (true) {
                        val n = input.read(chunk)
                        if (n <= 0) break
                        if (bytes.size() + n > 24 * 1024 * 1024) {
                            throw java.io.IOException("Verification exceeds export size limit")
                        }
                        bytes.write(chunk, 0, n)
                    }
                    bytes.toByteArray()
                } ?: throw java.io.IOException("Document provider refused readback")
                if (!expected.contentEquals(actual)) {
                    reply.success(mapOf("ok" to false, "error" to "verification-mismatch",
                        "bytes" to actual.size, "expectedBytes" to expected.size))
                    return
                }
                reply.success(mapOf("ok" to true, "verified" to true,
                    "bytes" to actual.size, "name" to name))
            } catch (error: Exception) {
                reply.success(mapOf("ok" to false, "error" to "write-or-readback-failed", "bytes" to 0))
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
