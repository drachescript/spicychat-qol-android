package uk.drache.spicychatqol

import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val appInfoChannel = "uk.drache.spicychatqol/app_info"

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

                else -> result.notImplemented()
            }
        }
    }
}
