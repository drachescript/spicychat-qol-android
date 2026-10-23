import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

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
  static const _experimentalKey = 'ds_android_qol_update_experimental';
  // Increment only for an APK change to the native bridge protocol.
  static const int androidBridgeVersion = 1;
  static const _repoApi =
      'https://api.github.com/repos/drachescript/spicychat-qol-extension';
  static const _rawBase =
      'https://raw.githubusercontent.com/drachescript/spicychat-qol-extension';

  // Unlike the old fixed file list, Options dependencies can now live under
  // settings/, shared/, background/, etc. (QoL 0.2.44+).
  static const _androidOptionsSupportFiles = <String>[
    'features.md',
    'CHANGELOG.md',
  ];

  static List<String> _optionDependenciesFromHtml(String html) {
    final tagPattern = RegExp(r'<(?:script|link)\b[^>]*>', caseSensitive: false);
    final sourcePattern = RegExp(
      r'''(?:src|href)\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    );
    final pathPattern = RegExp(
      r'^[A-Za-z0-9_./-]+\.(?:js|css)$',
      caseSensitive: false,
    );
    final required = <String>{};
    for (final tag in tagPattern.allMatches(html)) {
      final raw = sourcePattern.firstMatch(tag.group(0) ?? '')?.group(1) ?? '';
      final relative = raw.split(RegExp(r'[?#]')).first.trim();
      if (relative.isEmpty ||
          relative.startsWith('/') ||
          relative.startsWith('.') ||
          relative.contains('../') ||
          relative.contains('\\') ||
          !pathPattern.hasMatch(relative)) {
        continue;
      }
      required.add(relative);
    }
    return required.toList(growable: false);
  }

  SharedPreferences? _prefs;
  Directory? _root;
  Directory? _currentDir;

  DateTime? _lastCheckedAt;
  bool _checking = false;
  QolUpdateStatus _status = QolUpdateStatus.idle;
  String? _errorMessage;
  String _activeVersion = '';
  String _activeSha = '';
  bool _experimentalChannel = false;
  String? _selectedReleaseVersion;
  bool _activeHasHashes = false;
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
  bool get experimentalChannel => _experimentalChannel;
  String get updateChannel => _experimentalChannel
      ? 'Experimental (main)'
      : 'Stable releases';

  Future<void> setExperimentalChannel(bool enabled) async {
    if (_checking || _experimentalChannel == enabled) return;
    _experimentalChannel = enabled;
    _lastCheckedAt = null; // Recheck immediately on the chosen channel.
    await _prefs?.setBool(_experimentalKey, enabled);
    await _prefs?.remove(_lastCheckedKey);
    notifyListeners();
  }
  List<String> get runtimeJsPaths => List.unmodifiable(_runtimeJs);
  List<String> get runtimeCssPaths => List.unmodifiable(_runtimeCss);
  List<String> get webResourcePaths => List.unmodifiable(_webResources);
  bool get hasDownloadedBundle =>
      _currentDir != null &&
      _activeSha.isNotEmpty &&
      _runtimeJs.isNotEmpty;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _experimentalChannel = _prefs?.getBool(_experimentalKey) ?? false;
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
    // A partial/corrupt update must never strand a launch.
    if (!hasDownloadedBundle) {
      await rollbackToPrevious();
    }
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
      final optionsFiles = _stringList(map['optionsFiles']);
      final fileHashesRaw = map['fileHashes'];
      final hashes = fileHashesRaw is Map
          ? Map<String, dynamic>.from(fileHashesRaw)
          : <String, dynamic>{};
      final requiresHashes = (map['schemaVersion'] == 2);
      final sha = (map['sha'] ?? '').toString().trim();

      if (sha.isEmpty || runtimeJs.isEmpty) {
        _clearActiveMetadata();
        return;
      }

      // Reject older, incomplete downloaded bundles even when their commit
      // SHA hasn't changed. On the next check Android will redownload the same
      // release with the missing modular Settings assets.
      final optionsHtmlFile = File(_pathFor(current, 'options.html'));
      if (!await optionsHtmlFile.exists()) {
        _clearActiveMetadata();
        return;
      }
      final optionsHtml = await optionsHtmlFile.readAsString();
      final verifiedOptions = _orderedUnique([
        'options.html',
        ...optionsFiles,
        ..._optionDependenciesFromHtml(optionsHtml),
      ]);

      for (final relative in _orderedUnique([
        'manifest.json',
        ...runtimeJs,
        ...runtimeCss,
        ...webResources,
        ...verifiedOptions,
      ])) {
        final file = File(_pathFor(current, relative));
        if (!await file.exists()) {
          _clearActiveMetadata();
          return;
        }
        // Old v1 downloads are readable, but all newly downloaded v2
        // bundles must have every asset verified byte for byte.
        if (requiresHashes || hashes.isNotEmpty) {
          final expected = (hashes[relative] ?? '').toString();
          if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(expected) ||
              sha256.convert(await file.readAsBytes()).toString() !=
                  expected) {
            _clearActiveMetadata();
            return;
          }
        }
      }

      _activeVersion = (map['version'] ?? '').toString().trim();
      _activeSha = sha;
      _activeHasHashes = requiresHashes;
      _runtimeJs = runtimeJs;
      _runtimeCss = runtimeCss;
      _webResources = webResources;
    } catch (_) {
      _clearActiveMetadata();
    }
  }

  void _clearActiveMetadata() {
    _activeHasHashes = false;
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

      final remoteSha = await _fetchRemoteApprovedSha(client);
      if (remoteSha.isEmpty) {
        throw const FormatException('GitHub did not return a main-branch SHA.');
      }

      if (remoteSha == _activeSha && hasDownloadedBundle &&
          _activeHasHashes) {
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
      _checkManifestCompatibility(manifest);
      final incomingVersion =
          (manifest['version_name'] ?? manifest['version'] ?? '').toString().trim();
      if (!_experimentalChannel &&
          incomingVersion != _selectedReleaseVersion) {
        throw FormatException(
          'Stable release tag does not match its manifest version.',
        );
      }
      if (hasDownloadedBundle &&
          _compareNumericVersions(incomingVersion, _activeVersion) < 0) {
        throw StateError(
          'Refusing to downgrade QoL from $_activeVersion to $incomingVersion.',
        );
      }

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
        final fileHashes = <String, String>{};
        // All assets are hashed over their original downloaded bytes.
        // Images and future binary resources must never pass through UTF-8.
        Future<void> saveBytes(String relative, List<int> bytes) async {
          await _writeBytes(staging, relative, bytes);
          fileHashes[relative] = sha256.convert(bytes).toString();
        }
        Future<void> save(String relative, String value) async {
          await saveBytes(relative, utf8.encode(value));
        }
        await save('manifest.json', manifestText);

        final optionsPage = (manifest['options_page'] ?? 'options.html')
            .toString()
            .trim();
        if (optionsPage != 'options.html') {
          throw FormatException(
            'Android does not support this QoL Options page: $optionsPage',
          );
        }
        final optionsHtml = await _getText(
          client,
          '$_rawBase/$remoteSha/$optionsPage',
        );
        await save(optionsPage, optionsHtml);
        final optionsFiles = _orderedUnique([
          optionsPage,
          ..._optionDependenciesFromHtml(optionsHtml),
          ..._androidOptionsSupportFiles,
        ]);
        final required = _orderedUnique([
          ...js,
          ...css,
          ...web,
          ...optionsFiles.where((path) => path != optionsPage),
        ]);

        for (var offset = 0; offset < required.length; offset += 8) {
          final end =
              (offset + 8 < required.length) ? offset + 8 : required.length;
          final chunk = required.sublist(offset, end);

          await Future.wait(
            chunk.map(
              (relative) async {
                final url = '$_rawBase/$remoteSha/$relative';
                // Manifest JS/CSS, Options scripts and documentation are text;
                // PNG/JPEG/WebP/ICO and other web resources are raw bytes.
                // An unfamiliar extension is safely treated as binary.
                final textAsset = RegExp(
                  r'\.(?:js|css|html|json|md|txt|svg|xml)$',
                  caseSensitive: false,
                ).hasMatch(relative);
                if (textAsset) {
                  await save(relative, await _getText(client!, url));
                } else {
                  await saveBytes(relative, await _getBytes(client!, url));
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
            'schemaVersion': 2,
            'fileHashes': fileHashes,
            'version': version,
            'sha': remoteSha,
            'downloadedAt': DateTime.now().toUtc().toIso8601String(),
            'runtimeJs': js,
            'runtimeCss': css,
            'webResources': web,
            'optionsFiles': optionsFiles,
          }),
        );

        await _activateStaging(staging);
        try {
          await _loadActiveMetadata();
          if (!hasDownloadedBundle || _activeSha != remoteSha) {
            throw const FileSystemException(
              'Downloaded QoL bundle did not activate cleanly.',
            );
          }
          final callback = onBundleActivated;
          if (callback != null) await callback();
          // Previous bundle remains on disk for a future manual or
          // startup rollback. Never discard the last working version
          // just because the downloaded files exist.
          await _recordSuccessfulCheck();
          _status = QolUpdateStatus.updated;
        } catch (activationError) {
          if (!await rollbackToPrevious()) {
            await disableDownloadedBundle();
          }
          try {
            await onBundleActivated?.call();
          } catch (_) {
            // Keep the older bundle/fallback; report original error.
          }
          rethrow;
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

  /// Stable follows GitHub's latest published non-prerelease. Experimental
  /// deliberately follows main and can receive unpublished changes.
  Future<String> _fetchRemoteApprovedSha(HttpClient client) async {
    _selectedReleaseVersion = null;
    if (_experimentalChannel) {
      final raw = jsonDecode(await _getText(client, '$_repoApi/commits/main'));
      if (raw is! Map) return '';
      return (raw['sha'] ?? '').toString().trim();
    }
    final release = jsonDecode(await _getText(client, '$_repoApi/releases/latest'));
    if (release is! Map || release['draft'] == true ||
        release['prerelease'] == true) {
      throw const FormatException('No approved stable QoL release found.');
    }
    final tag = (release['tag_name'] ?? '').toString().trim();
    if (!RegExp(r'^v[0-9]+\.[0-9]+\.[0-9]+$').hasMatch(tag)) {
      throw FormatException('Invalid stable QoL release tag: $tag');
    }
    _selectedReleaseVersion = tag.substring(1);
    final commit = jsonDecode(await _getText(
      client, '$_repoApi/commits/${Uri.encodeComponent(tag)}',
    ));
    if (commit is! Map) return '';
    return (commit['sha'] ?? '').toString().trim();
  }

  static int _compareNumericVersions(String incoming, String current) {
    List<int>? parse(String value) {
      final match = RegExp(r'^([0-9]+)\.([0-9]+)\.([0-9]+)$').firstMatch(value);
      if (match == null) return null;
      return [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
    }
    final a = parse(incoming);
    final b = parse(current);
    if (a == null || b == null) return 0;
    for (var i = 0; i < 3; i++) {
      final diff = a[i].compareTo(b[i]);
      if (diff != 0) return diff;
    }
    return 0;
  }

  static void _checkManifestCompatibility(Map<String, dynamic> manifest) {
    final compatibility = manifest['androidCompatibility'];
    final rawVersion = compatibility is Map
        ? compatibility['minBridgeVersion']
        : manifest['minAndroidBridgeVersion'];
    final minimum = rawVersion == null ? 1 : int.tryParse(rawVersion.toString());
    if (minimum == null || minimum < 1) {
      throw const FormatException('Invalid minimum Android bridge version.');
    }
    final groups = manifest['content_scripts'];
    if (groups is List) {
      for (final group in groups) {
        if (group is! Map || group['world'] != 'MAIN') continue;
        final paths = group['js'];
        if (paths is! List) continue;
        for (final path in paths) {
          if (path != 'content/card-token-main.js') {
            throw StateError('New MAIN-world script requires Android review: $path');
          }
        }
      }
    }
    if (minimum > androidBridgeVersion) {
      throw StateError('QoL requires Android bridge $minimum; this APK has '
          '$androidBridgeVersion. Update the Android APK first.');
    }
    final required = compatibility is Map
        ? compatibility['requiredNativeFeatures']
        : null;
    if (required != null && (required is! List || required.isNotEmpty)) {
      throw StateError('QoL requires additional native Android features. '
          'Update the Android APK first.');
    }
  }

  Future<void> _recordSuccessfulCheck() async {
    final now = DateTime.now();
    _lastCheckedAt = now;
    await _prefs?.setInt(
      _lastCheckedKey,
      now.millisecondsSinceEpoch,
    );
  }

  // DS_ANDROID_V057_BINARY_RESOURCE_FIX: stream original bytes instead of
  // passing binary manifest resources through a UTF-8 text decoder.
  Future<Uint8List> _getBytes(HttpClient client, String rawUrl) async {
    final uri = Uri.parse(rawUrl);
    final request = await client.getUrl(uri);
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'SpicyChat-QOL-Android/QoL-Updater',
    );
    request.headers.set(HttpHeaders.acceptHeader, '*/*');
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>();
      throw HttpException(
        'HTTP ${response.statusCode} for $rawUrl',
        uri: uri,
      );
    }
    final chunks = await response.fold<BytesBuilder>(
      BytesBuilder(copy: false),
      (builder, chunk) {
        if (builder.length + chunk.length > 8 * 1024 * 1024) {
          throw const FormatException('Downloaded QoL asset exceeds 8 MiB.');
        }
        builder.add(chunk);
        return builder;
      },
    ).timeout(const Duration(seconds: 45));
    return chunks.takeBytes();
  }

  Future<String> _getText(HttpClient client, String rawUrl) async {
    final bytes = await _getBytes(client, rawUrl);
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw FormatException('Expected a UTF-8 QoL text asset: $rawUrl');
    }
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

  Future<void> _writeBytes(
    Directory base,
    String relative,
    List<int> bytes,
  ) async {
    final file = File(_pathFor(base, relative));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  Future<void> _writeText(
    Directory base,
    String relative,
    String text,
  ) async {
    await _writeBytes(base, relative, utf8.encode(text));
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
      // Retain previous until another successfully staged update.
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

  /// User-invoked recovery. Switching bundle data does not touch account
  /// preferences or data and takes effect on the next page load.
  Future<bool> restoreWorkingBundle() async {
    if (_checking) return false;
    final restoredPrevious = await rollbackToPrevious();
    if (!restoredPrevious) await disableDownloadedBundle();
    await onBundleActivated?.call();
    _status = QolUpdateStatus.idle;
    _errorMessage = null;
    notifyListeners();
    return restoredPrevious;
  }

  /// Restore the last downloaded working version without affecting user
  /// settings, login state, backups, or synced lists.
  Future<bool> rollbackToPrevious() async {
    final root = _root;
    final current = _currentDir;
    if (root == null || current == null) return false;
    final previous = Directory('${root.path}${Platform.pathSeparator}previous');
    if (!await previous.exists()) return false;
    final rejected = Directory(
      '${root.path}${Platform.pathSeparator}rejected-${DateTime.now().millisecondsSinceEpoch}',
    );
    final existed = await current.exists();
    if (existed) await current.rename(rejected.path);
    try {
      await previous.rename(current.path);
      await _loadActiveMetadata();
      if (!hasDownloadedBundle) {
        // Corrupt previous release is not a working fallback.
        if (await current.exists()) await current.delete(recursive: true);
        if (existed) await rejected.rename(current.path);
        _clearActiveMetadata();
        return false;
      }
      if (await rejected.exists()) await rejected.delete(recursive: true);
      notifyListeners();
      return true;
    } catch (_) {
      if (await current.exists()) await current.delete(recursive: true);
      if (existed && await rejected.exists()) {
        await rejected.rename(current.path);
      }
      _clearActiveMetadata();
      return false;
    }
  }

  /// Emergency fallback to the immutable JS/CSS bundled in the APK.
  Future<void> disableDownloadedBundle() async {
    final current = _currentDir;
    if (current != null && await current.exists()) {
      await current.delete(recursive: true);
    }
    _clearActiveMetadata();
    notifyListeners();
  }

  // Only web-accessible image resources may be requested as APK data URLs.
  // The v2 metadata and SHA-256 checks have already verified these bytes.
  Future<List<int>?> readDownloadedImage(String relative) async {
    final current = _currentDir;
    if (!hasDownloadedBundle || current == null ||
        !_webResources.contains(relative) ||
        !RegExp(r'\.(?:png|jpe?g|webp|gif|ico)$', caseSensitive: false)
            .hasMatch(relative)) {
      return null;
    }
    try {
      final file = File(_pathFor(current, relative));
      if (!await file.exists() || await file.length() > 2 * 1024 * 1024) {
        return null;
      }
      return await file.readAsBytes();
    } catch (_) {
      return null;
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
