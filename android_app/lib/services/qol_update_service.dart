import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum QolUpdateStatus {
  idle,
  checking,
  upToDate,
  updated,
  error,
}

class QolUpdateService extends ChangeNotifier {
  static const automaticCheckInterval = Duration(hours: 12);

  static const _lastCheckedKey = 'ds_android_qol_update_last_checked_ms';
  static const _repoApi =
      'https://api.github.com/repos/drachescript/spicychat-qol-extension';
  static const _rawBase =
      'https://raw.githubusercontent.com/drachescript/spicychat-qol-extension';

  static const _androidOptionsFiles = <String>[
    'options.html',
    'options.css',
    'options.js',
    'feature-registry.js',
    'creator-follow-consent.js',
    'features.md',
    'CHANGELOG.md',
  ];

  SharedPreferences? _prefs;
  Directory? _root;
  Directory? _currentDir;

  DateTime? _lastCheckedAt;
  bool _checking = false;
  QolUpdateStatus _status = QolUpdateStatus.idle;
  String? _errorMessage;
  String _activeVersion = '';
  String _activeSha = '';
  List<String> _runtimeJs = const [];
  List<String> _runtimeCss = const [];
  List<String> _webResources = const [];

  Future<void> Function()? onBundleActivated;

  bool get checking => _checking;
  QolUpdateStatus get status => _status;
  String? get errorMessage => _errorMessage;
  DateTime? get lastCheckedAt => _lastCheckedAt;
  String get activeVersion => _activeVersion;
  String get activeSha => _activeSha;
  List<String> get runtimeJsPaths => List.unmodifiable(_runtimeJs);
  List<String> get runtimeCssPaths => List.unmodifiable(_runtimeCss);
  List<String> get webResourcePaths => List.unmodifiable(_webResources);
  bool get hasDownloadedBundle =>
      _currentDir != null &&
      _activeSha.isNotEmpty &&
      _runtimeJs.isNotEmpty;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final last = _prefs?.getInt(_lastCheckedKey);
    if (last != null && last > 0) {
      _lastCheckedAt = DateTime.fromMillisecondsSinceEpoch(last);
    }

    final support = await getApplicationSupportDirectory();
    _root = Directory('${support.path}${Platform.pathSeparator}qol_updates');
    await _root!.create(recursive: true);
    _currentDir =
        Directory('${_root!.path}${Platform.pathSeparator}current');

    await _loadActiveMetadata();
  }

  Future<void> _loadActiveMetadata() async {
    final current = _currentDir;
    if (current == null || !await current.exists()) {
      _clearActiveMetadata();
      return;
    }

    final metadataFile =
        File('${current.path}${Platform.pathSeparator}metadata.json');
    if (!await metadataFile.exists()) {
      _clearActiveMetadata();
      return;
    }

    try {
      final decoded = jsonDecode(await metadataFile.readAsString());
      if (decoded is! Map) {
        _clearActiveMetadata();
        return;
      }

      final map = Map<String, dynamic>.from(decoded);
      final runtimeJs = _stringList(map['runtimeJs']);
      final runtimeCss = _stringList(map['runtimeCss']);
      final webResources = _stringList(map['webResources']);
      final sha = (map['sha'] ?? '').toString().trim();

      if (sha.isEmpty || runtimeJs.isEmpty) {
        _clearActiveMetadata();
        return;
      }

      for (final relative in [
        'manifest.json',
        ...runtimeJs,
        ...runtimeCss,
        ...webResources,
      ]) {
        if (!await File(_pathFor(current, relative)).exists()) {
          _clearActiveMetadata();
          return;
        }
      }

      _activeVersion = (map['version'] ?? '').toString().trim();
      _activeSha = sha;
      _runtimeJs = runtimeJs;
      _runtimeCss = runtimeCss;
      _webResources = webResources;
    } catch (_) {
      _clearActiveMetadata();
    }
  }

  void _clearActiveMetadata() {
    _activeVersion = '';
    _activeSha = '';
    _runtimeJs = const [];
    _runtimeCss = const [];
    _webResources = const [];
  }

  List<String> _stringList(dynamic value) {
    if (value is! List) return const [];
    return value
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  bool get _automaticCheckDue {
    final checked = _lastCheckedAt;
    if (checked == null) return true;
    return DateTime.now().difference(checked) >= automaticCheckInterval;
  }

  Future<bool> maybeCheckAutomatically() async {
    if (!_automaticCheckDue || _checking) return false;
    await checkForUpdates(manual: false);
    return true;
  }

  Future<void> checkForUpdates({bool manual = false}) async {
    if (_checking) return;
    if (!manual && !_automaticCheckDue) return;

    _checking = true;
    _status = QolUpdateStatus.checking;
    _errorMessage = null;
    notifyListeners();

    HttpClient? client;

    try {
      client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 12)
        ..idleTimeout = const Duration(seconds: 12);

      final remoteSha = await _fetchRemoteMainSha(client);
      if (remoteSha.isEmpty) {
        throw const FormatException('GitHub did not return a main-branch SHA.');
      }

      if (remoteSha == _activeSha && hasDownloadedBundle) {
        await _recordSuccessfulCheck();
        _status = QolUpdateStatus.upToDate;
        return;
      }

      final manifestText = await _getText(
        client,
        '$_rawBase/$remoteSha/manifest.json',
      );
      final manifestRaw = jsonDecode(manifestText);
      if (manifestRaw is! Map) {
        throw const FormatException('QoL manifest.json was not an object.');
      }
      final manifest = Map<String, dynamic>.from(manifestRaw);

      final runtimeJs = <String>[];
      final runtimeCss = <String>[];

      final contentScripts = manifest['content_scripts'];
      if (contentScripts is List) {
        for (final group in contentScripts) {
          if (group is! Map) continue;
          runtimeJs.addAll(_stringList(group['js']));
          runtimeCss.addAll(_stringList(group['css']));
        }
      }

      final webResources = <String>[];
      final resources = manifest['web_accessible_resources'];
      if (resources is List) {
        for (final group in resources) {
          if (group is! Map) continue;
          webResources.addAll(_stringList(group['resources']));
        }
      }

      final js = _orderedUnique(runtimeJs);
      final css = _orderedUnique(runtimeCss);
      final web = _orderedUnique(webResources);

      if (js.isEmpty) {
        throw const FormatException(
          'QoL manifest contained no content scripts.',
        );
      }

      final staging = Directory(
        '${_root!.path}${Platform.pathSeparator}'
        'staging-${DateTime.now().millisecondsSinceEpoch}',
      );
      await staging.create(recursive: true);

      try {
        await _writeText(staging, 'manifest.json', manifestText);

        final required = <String>[
          ...js,
          ...css,
          ...web,
          ..._androidOptionsFiles,
        ];

        for (var offset = 0; offset < required.length; offset += 8) {
          final end =
              (offset + 8 < required.length) ? offset + 8 : required.length;
          final chunk = required.sublist(offset, end);

          await Future.wait(
            chunk.map(
              (relative) async {
                try {
                  final text = await _getText(
                    client!,
                    '$_rawBase/$remoteSha/$relative',
                  );
                  await _writeText(staging, relative, text);
                } on HttpException catch (error) {
                  if (relative == 'creator-follow-consent.js' &&
                      error.message.contains('404')) {
                    return;
                  }
                  rethrow;
                }
              },
            ),
          );
        }

        final version = (manifest['version_name'] ??
                manifest['version'] ??
                'unknown')
            .toString()
            .trim();

        await _writeText(
          staging,
          'metadata.json',
          const JsonEncoder.withIndent('  ').convert({
            'schemaVersion': 1,
            'version': version,
            'sha': remoteSha,
            'downloadedAt': DateTime.now().toUtc().toIso8601String(),
            'runtimeJs': js,
            'runtimeCss': css,
            'webResources': web,
            'optionsFiles': _androidOptionsFiles,
          }),
        );

        await _activateStaging(staging);
        await _loadActiveMetadata();

        if (!hasDownloadedBundle || _activeSha != remoteSha) {
          throw const FileSystemException(
            'Downloaded QoL bundle did not activate cleanly.',
          );
        }

        await _recordSuccessfulCheck();
        _status = QolUpdateStatus.updated;

        final callback = onBundleActivated;
        if (callback != null) {
          await callback();
        }
      } catch (_) {
        if (await staging.exists()) {
          await staging.delete(recursive: true);
        }
        rethrow;
      }
    } catch (error) {
      _status = QolUpdateStatus.error;
      _errorMessage = 'QoL update check failed: $error';
    } finally {
      client?.close(force: true);
      _checking = false;
      notifyListeners();
    }
  }

  Future<String> _fetchRemoteMainSha(HttpClient client) async {
    final text = await _getText(client, '$_repoApi/commits/main');
    final decoded = jsonDecode(text);
    if (decoded is! Map) return '';
    return (decoded['sha'] ?? '').toString().trim();
  }

  Future<void> _recordSuccessfulCheck() async {
    final now = DateTime.now();
    _lastCheckedAt = now;
    await _prefs?.setInt(
      _lastCheckedKey,
      now.millisecondsSinceEpoch,
    );
  }

  Future<String> _getText(HttpClient client, String rawUrl) async {
    final request = await client.getUrl(Uri.parse(rawUrl));
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'SpicyChat-QOL-Android/QoL-Updater',
    );
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/json,text/plain,*/*',
    );

    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'HTTP ${response.statusCode} for $rawUrl',
        uri: Uri.parse(rawUrl),
      );
    }

    return text;
  }

  List<String> _orderedUnique(List<String> input) {
    final seen = <String>{};
    final result = <String>[];
    for (final item in input) {
      final normalized = item.trim();
      if (normalized.isEmpty || !seen.add(normalized)) continue;
      result.add(normalized);
    }
    return result;
  }

  String _safeRelative(String relative) {
    final normalized = relative.replaceAll('\\', '/').trim();
    if (normalized.isEmpty ||
        normalized.startsWith('/') ||
        normalized.contains('../') ||
        normalized == '..') {
      throw ArgumentError.value(relative, 'relative', 'Unsafe bundle path');
    }
    return normalized;
  }

  String _pathFor(Directory base, String relative) {
    final safe = _safeRelative(relative);
    return '${base.path}${Platform.pathSeparator}'
        '${safe.replaceAll('/', Platform.pathSeparator)}';
  }

  Future<void> _writeText(
    Directory base,
    String relative,
    String text,
  ) async {
    final file = File(_pathFor(base, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(text, flush: true);
  }

  Future<void> _activateStaging(Directory staging) async {
    final current = _currentDir!;
    final backup = Directory(
      '${_root!.path}${Platform.pathSeparator}previous',
    );

    if (await backup.exists()) {
      await backup.delete(recursive: true);
    }

    if (await current.exists()) {
      await current.rename(backup.path);
    }

    try {
      await staging.rename(current.path);
      if (await backup.exists()) {
        await backup.delete(recursive: true);
      }
    } catch (_) {
      if (await current.exists()) {
        await current.delete(recursive: true);
      }
      if (await backup.exists()) {
        await backup.rename(current.path);
      }
      rethrow;
    }
  }

  Future<String?> readDownloadedText(String relative) async {
    final current = _currentDir;
    if (current == null || !hasDownloadedBundle) return null;

    try {
      final file = File(_pathFor(current, relative));
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }
}
