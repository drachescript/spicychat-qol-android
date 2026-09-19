import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';
import 'services/settings_service.dart';
import 'services/js_bundle_service.dart';
import 'services/app_log_service.dart';
import 'services/android_tabs_service.dart';
import 'services/android_ui_service.dart';
import 'screens/webview_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final appLog = AppLogService.instance;
  await appLog.init();
  unawaited(appLog.log('Startup', 'Application process starting'));

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    unawaited(
      appLog.log(
        'FlutterError',
        details.exceptionAsString(),
        level: 'ERROR',
        error: details.exception,
        stackTrace: details.stack,
      ),
    );
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    unawaited(
      appLog.log(
        'PlatformError',
        'Unhandled platform/Dart error',
        level: 'ERROR',
        error: error,
        stackTrace: stack,
      ),
    );
    return true;
  };

  // Initialize InAppWebView debugging (debug builds only)
  if (defaultTargetPlatform == TargetPlatform.android && kDebugMode) {
    try {
      await InAppWebViewController.setWebContentsDebuggingEnabled(true);
    } catch (e, stackTrace) {
      unawaited(
        appLog.log(
          'Startup',
          'Could not enable WebView debugging',
          level: 'WARN',
          error: e,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  // Initialize services
  final settingsService = SettingsService();
  try {
    await settingsService.init();
    unawaited(
      appLog.log(
        'Startup',
        settingsService.persistentStorageAvailable
            ? 'Settings service initialized'
            : 'Settings service running in temporary memory fallback mode',
        level: settingsService.persistentStorageAvailable ? 'INFO' : 'WARN',
      ),
    );
  } catch (e, stackTrace) {
    // Startup must never terminate solely because local preference storage is
    // damaged/unavailable. SettingsService is designed to fall back safely.
    unawaited(
      appLog.log(
        'Startup',
        'Settings service initialization reported an error; continuing',
        level: 'ERROR',
        error: e,
        stackTrace: stackTrace,
      ),
    );
  }

  final tabsService = AndroidTabsService();
  try {
    await tabsService.init();
    unawaited(
      appLog.log(
        'Startup',
        tabsService.enabled
            ? 'Android chat tabs initialized (opt-in enabled)'
            : 'Android chat tabs disabled',
      ),
    );
  } catch (e, stackTrace) {
    unawaited(
      appLog.log(
        'Startup',
        'Android chat-tab service initialization failed; continuing disabled',
        level: 'ERROR',
        error: e,
        stackTrace: stackTrace,
      ),
    );
  }

  final androidUiService = AndroidUiService();
  try {
    await androidUiService.init();
    unawaited(
      appLog.log(
        'Startup',
        'Android UI preferences initialized',
      ),
    );
  } catch (e, stackTrace) {
    unawaited(
      appLog.log(
        'Startup',
        'Android UI preference initialization failed; using defaults',
        level: 'WARN',
        error: e,
        stackTrace: stackTrace,
      ),
    );
  }

  final bundleService = JsBundleService();
  try {
    // Never leave the native launch screen up forever because one bundled
    // extension asset failed to load. The WebView can still start without
    // QoL injection and the next build can fix the broken asset.
    await bundleService.loadAssets().timeout(const Duration(seconds: 15));
    unawaited(appLog.log('Startup', 'QoL bundle assets loaded'));
  } catch (e, stackTrace) {
    unawaited(
      appLog.log(
        'Startup',
        'QoL bundle load failed or timed out; continuing without blocking startup',
        level: 'ERROR',
        error: e,
        stackTrace: stackTrace,
      ),
    );
  }

  unawaited(appLog.log('Startup', 'Launching Flutter UI'));

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settingsService),
        ChangeNotifierProvider.value(value: tabsService),
        ChangeNotifierProvider.value(value: androidUiService),
      ],
      child: SpicyChatQolApp(bundleService: bundleService),
    ),
  );
}

class SpicyChatQolApp extends StatelessWidget {
  final JsBundleService bundleService;

  const SpicyChatQolApp({super.key, required this.bundleService});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SpicyChat QOL',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.deepPurple,
        scaffoldBackgroundColor: const Color(0xFF0F0F1A),
        colorScheme: const ColorScheme.dark(
          primary: Colors.deepPurpleAccent,
          surface: Color(0xFF1A1A2E),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1A1A2E),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
      ),
      home: WebViewScreen(bundleService: bundleService),
    );
  }
}
