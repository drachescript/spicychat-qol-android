package uk.drache.spicychatqol

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
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
