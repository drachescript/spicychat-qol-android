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
import 'services/android_update_service.dart';
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

  final androidUpdateService = AndroidUpdateService();
  try {
    await androidUpdateService.init();
    unawaited(
      appLog.log(
        'Startup',
        'Android update service initialized',
      ),
    );
  } catch (e, stackTrace) {
    unawaited(
      appLog.log(
        'Startup',
        'Android update service initialization failed; manual checks may retry',
        level: 'WARN',
        error: e,
        stackTrace: stackTrace,
      ),
    );
  }

  final bundleService = JsBundleService();
  try {
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
        ChangeNotifierProvider.value(value: androidUpdateService),
      ],
      child: SpicyChatQolApp(bundleService: bundleService),
    ),
  );
}

class SpicyChatQolApp extends StatefulWidget {
  final JsBundleService bundleService;

  const SpicyChatQolApp({super.key, required this.bundleService});

  @override
  State<SpicyChatQolApp> createState() => _SpicyChatQolAppState();
}

class _SpicyChatQolAppState extends State<SpicyChatQolApp> {
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  bool _automaticUpdateCheckStarted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (_automaticUpdateCheckStarted) return;
    _automaticUpdateCheckStarted = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_runAutomaticAndroidUpdateCheck());
    });
  }

  Future<void> _runAutomaticAndroidUpdateCheck() async {
    final updates = Provider.of<AndroidUpdateService>(
      context,
      listen: false,
    );

    final didCheck = await updates.maybeCheckAutomatically();

    if (!mounted || !didCheck || !updates.updateAvailable) {
      return;
    }

    final latest = updates.latest;
    if (latest == null) return;

    _messengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(
          'Android update available: v${latest.versionName}',
        ),
        duration: const Duration(seconds: 10),
        action: SnackBarAction(
          label: 'UPDATE',
          onPressed: () {
            unawaited(updates.openLatestUpdatePage());
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SpicyChat QOL',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _messengerKey,
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
      home: WebViewScreen(bundleService: widget.bundleService),
    );
  }
}
