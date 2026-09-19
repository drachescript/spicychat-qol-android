import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/settings_service.dart';

/// Displays the extension's real options.html inside the Android app.
///
/// This intentionally uses the same HTML/CSS/JS as the desktop extension so
/// newly added QOL settings do not need to be recreated as Flutter widgets.
class OptionsScreen extends StatefulWidget {
  final Future<void> Function() onSettingsChanged;
  final String extensionVersion;
  final Future<Map<String, dynamic>?> Function() onQueryMainTab;
  final Future<dynamic> Function(dynamic message) onSendMainTabMessage;

  const OptionsScreen({
    super.key,
    required this.onSettingsChanged,
    required this.extensionVersion,
    required this.onQueryMainTab,
    required this.onSendMainTabMessage,
  });

  @override
  State<OptionsScreen> createState() => _OptionsScreenState();
}

class _OptionsScreenState extends State<OptionsScreen> {
  bool _isLoading = true;
  double _progress = 0;
  bool _storageChanged = false;

  @override
  void dispose() {
    if (_storageChanged) {
      widget.onSettingsChanged();
    }
    super.dispose();
  }

  String _safeNativeFilename(dynamic value, {required String fallback}) {
    var filename = (value ?? '').toString().trim();
    if (filename.isEmpty) filename = fallback;

    filename = filename
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (filename.isEmpty) return fallback;
    if (filename.length > 140) {
      final dot = filename.lastIndexOf('.');
      final suffix = dot > 0 && filename.length - dot <= 12
          ? filename.substring(dot)
          : '';
      final keep = 140 - suffix.length;
      filename = '${filename.substring(0, keep)}$suffix';
    }
    return filename;
  }

  Map<String, dynamic>? _decodeNativeSaveArgs(List<dynamic> args) {
    if (args.isEmpty) return null;
    dynamic raw = args.first;

    if (raw is String) {
      try {
        raw = jsonDecode(raw);
      } catch (_) {
        return null;
      }
    }
    if (raw is! Map) return null;
    return Map<String, dynamic>.from(raw);
  }

  Uint8List _nativeSaveBytes(Map<String, dynamic> data) {
    final encoded = data['base64'];
    if (encoded is String && encoded.trim().isNotEmpty) {
      try {
        final clean = encoded.contains(',')
            ? encoded.substring(encoded.indexOf(',') + 1)
            : encoded;
        return Uint8List.fromList(base64Decode(clean));
      } catch (_) {
        // Fall through to textual payload.
      }
    }

    return Uint8List.fromList(
      utf8.encode('${data['text'] ?? data['content'] ?? ''}'),
    );
  }

  Future<Map<String, dynamic>> _saveFromOptionsBridge(
    List<dynamic> args, {
    String dialogTitle = 'Save File',
  }) async {
    try {
      final data = _decodeNativeSaveArgs(args);
      if (data == null) return {'ok': false, 'error': 'invalid payload'};

      final filename = _safeNativeFilename(
        data['filename'] ?? data['fileName'],
        fallback: 'spicychat-qol-export.txt',
      );
      final bytes = _nativeSaveBytes(data);

      final dot = filename.lastIndexOf('.');
      final extension = dot >= 0 && dot < filename.length - 1
          ? filename.substring(dot + 1).toLowerCase()
          : null;
      final safeExtension = extension != null &&
              RegExp(r'^[a-z0-9]{1,12}$').hasMatch(extension)
          ? extension
          : null;

      final outputFile = await FilePicker.platform.saveFile(
        dialogTitle: dialogTitle,
        fileName: filename,
        type: safeExtension == null ? FileType.any : FileType.custom,
        allowedExtensions: safeExtension == null ? null : [safeExtension],
        bytes: bytes,
      );

      if (outputFile == null) return {'ok': false, 'canceled': true};

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved ${outputFile.split("/").last}')),
        );
      }
      return {'ok': true, 'name': filename};
    } catch (e) {
      debugPrint('[Options] native save error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
      return {'ok': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>?> _pickFileForOptionsBridge(
    List<dynamic> args,
  ) async {
    try {
      dynamic raw;
      if (args.isNotEmpty) raw = args.first;
      if (raw is String && raw.trim().isNotEmpty) {
        try {
          raw = jsonDecode(raw);
        } catch (_) {
          raw = null;
        }
      }

      final data = raw is Map
          ? Map<String, dynamic>.from(raw)
          : const <String, dynamic>{};
      final requested = data['allowedExtensions'];
      final allowedExtensions = requested is List
          ? requested
              .map((value) => value.toString().toLowerCase().trim())
              .where((value) => RegExp(r'^[a-z0-9]{1,12}$').hasMatch(value))
              .toSet()
              .toList()
          : <String>[];

      final result = await FilePicker.platform.pickFiles(
        type: allowedExtensions.isEmpty ? FileType.any : FileType.custom,
        allowedExtensions:
            allowedExtensions.isEmpty ? null : allowedExtensions,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return null;

      final picked = result.files.first;
      Uint8List? bytes = picked.bytes;
      if (bytes == null && picked.path != null) {
        bytes = await File(picked.path!).readAsBytes();
      }
      if (bytes == null) return null;

      return {
        'name': picked.name,
        'fileName': picked.name,
        'filename': picked.name,
        'text': utf8.decode(bytes, allowMalformed: true),
        'base64': base64Encode(bytes),
      };
    } catch (e) {
      debugPrint('[Options] native picker error: $e');
      return null;
    }
  }

  bool _isSpicyChatUrl(Uri uri) {
    final host = uri.host.toLowerCase();
    return (uri.scheme == 'http' || uri.scheme == 'https') &&
        (host == 'spicychat.ai' || host.endsWith('.spicychat.ai'));
  }

  void _openSpicyChatInMainWebView(Uri uri) {
    if (!mounted) return;
    Navigator.of(context).pop(uri.toString());
  }

  void _registerHandlers(InAppWebViewController controller) {
    final settingsService = Provider.of<SettingsService>(
      context,
      listen: false,
    );

    controller.addJavaScriptHandler(
      handlerName: 'optionsStorageGet',
      callback: (args) async {
        try {
          final rawKeys = args.isNotEmpty ? args.first?.toString() : null;
          final keys = rawKeys == null || rawKeys.isEmpty
              ? null
              : jsonDecode(rawKeys);
          final result = await settingsService.storageGet(keys);
          return jsonEncode(result);
        } catch (e) {
          debugPrint('[Options] storageGet error: $e');
          return '{}';
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'optionsStorageSet',
      callback: (args) async {
        try {
          if (args.isEmpty) return null;
          final decoded = jsonDecode(args.first.toString());
          if (decoded is! Map) return null;

          await settingsService.storageSet(
            Map<String, dynamic>.from(decoded),
          );
          _storageChanged = true;
        } catch (e) {
          debugPrint('[Options] storageSet error: $e');
        }
        return null;
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'optionsStorageRemove',
      callback: (args) async {
        try {
          final rawKeys = args.isNotEmpty ? args.first?.toString() : null;
          final keys = rawKeys == null || rawKeys.isEmpty
              ? const <dynamic>[]
              : jsonDecode(rawKeys);
          await settingsService.storageRemove(keys);
          _storageChanged = true;
        } catch (e) {
          debugPrint('[Options] storageRemove error: $e');
        }
        return null;
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'optionsStorageGetBytesInUse',
      callback: (args) async {
        try {
          final rawKeys = args.isNotEmpty ? args.first?.toString() : null;
          final keys = rawKeys == null || rawKeys.isEmpty
              ? null
              : jsonDecode(rawKeys);
          return await settingsService.storageGetBytesInUse(keys);
        } catch (e) {
          debugPrint('[Options] storageGetBytesInUse error: $e');
          return 0;
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'optionsStorageClear',
      callback: (args) async {
        try {
          await settingsService.storageClear();
          _storageChanged = true;
        } catch (e) {
          debugPrint('[Options] storageClear error: $e');
        }
        return null;
      },
    );

    // Browser extension downloads do not reliably work from a local
    // file:// options page inside Android WebView. Route them through the same
    // native file picker used by the app's cogwheel backup.
    controller.addJavaScriptHandler(
      handlerName: 'exportChat',
      callback: (args) => _saveFromOptionsBridge(
        args,
        dialogTitle: 'Save Export',
      ),
    );

    controller.addJavaScriptHandler(
      handlerName: 'saveFile',
      callback: (args) => _saveFromOptionsBridge(args),
    );

    controller.addJavaScriptHandler(
      handlerName: 'pickFiles',
      callback: (args) => _pickFileForOptionsBridge(args),
    );

    // Android Options is a separate local WebView, so normal extension
    // background/tabs messaging cannot discover the live SpicyChat page.
    // Expose only the one real main WebView as a synthetic active tab.
    controller.addJavaScriptHandler(
      handlerName: 'optionsMainTabQuery',
      callback: (args) async {
        try {
          return await widget.onQueryMainTab();
        } catch (e) {
          debugPrint('[Options] main tab query error: $e');
          return null;
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'optionsMainTabMessage',
      callback: (args) async {
        if (args.isEmpty) return null;

        try {
          final decoded = jsonDecode(args.first.toString());
          return await widget.onSendMainTabMessage(decoded);
        } catch (e) {
          debugPrint('[Options] main runtime message error: $e');
          return null;
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'optionsReadBundledText',
      callback: (args) async {
        if (args.isEmpty) return null;
        final name = args.first.toString();
        if (name != 'CHANGELOG.md' && name != 'features.md') {
          return null;
        }

        try {
          return await rootBundle.loadString('assets/options/$name');
        } catch (e) {
          debugPrint('[Options] Could not read bundled $name: $e');
          return null;
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'optionsOpenMainAction',
      callback: (args) async {
        if (args.isEmpty || !mounted) return false;

        final action = args.first.toString().trim();
        if (action == 'commandPalette') {
          Navigator.of(context).pop('ds-action:command-palette');
          return true;
        }

        return false;
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'optionsOpenExternal',
      callback: (args) async {
        if (args.isEmpty) return false;
        final uri = Uri.tryParse(args.first.toString());
        if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
          return false;
        }

        // The Options bridge sends every normal HTTP(S) link through this
        // handler. Keep SpicyChat destinations inside the APK; only genuinely
        // external destinations should leave for the system browser.
        if (_isSpicyChatUrl(uri)) {
          _openSpicyChatInMainWebView(uri);
          return true;
        }

        try {
          return await launchUrl(
            uri,
            mode: LaunchMode.externalApplication,
          );
        } catch (e) {
          debugPrint('[Options] Could not open $uri: $e');
          return false;
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SpicyChat QOL Options'),
      ),
      body: Stack(
        children: [
          InAppWebView(
            initialFile: 'assets/options/options.html',
            initialUserScripts: UnmodifiableListView<UserScript>([
              UserScript(
                source:
                    'window.__spicyChatQolBundledVersion = ${jsonEncode(widget.extensionVersion)};',
                injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
              ),
            ]),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              javaScriptCanOpenWindowsAutomatically: true,
              supportMultipleWindows: true,
              domStorageEnabled: true,
              allowFileAccess: true,
              allowContentAccess: true,
              allowFileAccessFromFileURLs: true,
              allowUniversalAccessFromFileURLs: false,
              useShouldOverrideUrlLoading: true,
              supportZoom: false,
              builtInZoomControls: false,
              displayZoomControls: false,
            ),
            onWebViewCreated: _registerHandlers,
            onLoadStart: (_, __) {
              if (mounted) setState(() => _isLoading = true);
            },
            onLoadStop: (_, __) {
              if (mounted) setState(() => _isLoading = false);
            },
            onProgressChanged: (_, progress) {
              if (mounted) {
                setState(() => _progress = progress / 100);
              }
            },
            onCreateWindow: (_, action) async {
              final url = action.request.url;
              if (url == null) return false;

              if (_isSpicyChatUrl(url)) {
                _openSpicyChatInMainWebView(url);
                return false;
              }

              if (url.scheme == 'http' || url.scheme == 'https') {
                try {
                  await launchUrl(
                    url,
                    mode: LaunchMode.externalApplication,
                  );
                } catch (e) {
                  debugPrint('[Options] Could not open popup $url: $e');
                }
              }
              return false;
            },
            shouldOverrideUrlLoading: (_, action) async {
              final url = action.request.url;
              if (url == null || url.scheme == 'file') {
                return NavigationActionPolicy.ALLOW;
              }

              if (_isSpicyChatUrl(url)) {
                _openSpicyChatInMainWebView(url);
                return NavigationActionPolicy.CANCEL;
              }

              if (url.scheme == 'http' || url.scheme == 'https') {
                try {
                  await launchUrl(
                    url,
                    mode: LaunchMode.externalApplication,
                  );
                } catch (e) {
                  debugPrint('[Options] Could not open $url: $e');
                }
                return NavigationActionPolicy.CANCEL;
              }

              return NavigationActionPolicy.CANCEL;
            },
            onConsoleMessage: (_, message) {
              if (kDebugMode) {
                debugPrint('[Options Console] ${message.message}');
              }
            },
          ),
          if (_isLoading)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                minHeight: 3,
              ),
            ),
        ],
      ),
    );
  }
}
