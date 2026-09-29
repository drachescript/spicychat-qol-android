import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log_service.dart';

class AndroidUpdateInfo {
  final String versionName;
  final int? versionCode;
  final String tag;
  final String releaseUrl;
  final String? apkUrl;
  final String? sha256;
  final String source;

  const AndroidUpdateInfo({
    required this.versionName,
    required this.versionCode,
    required this.tag,
    required this.releaseUrl,
    required this.apkUrl,
    required this.sha256,
    required this.source,
  });

  AndroidUpdateInfo copyWith({
    String? versionName,
    int? versionCode,
    String? tag,
    String? releaseUrl,
    String? apkUrl,
    String? sha256,
    String? source,
  }) {
    return AndroidUpdateInfo(
      versionName: versionName ?? this.versionName,
      versionCode: versionCode ?? this.versionCode,
      tag: tag ?? this.tag,
      releaseUrl: releaseUrl ?? this.releaseUrl,
      apkUrl: apkUrl ?? this.apkUrl,
      sha256: sha256 ?? this.sha256,
      source: source ?? this.source,
    );
  }
}

enum AndroidUpdateStatus {
  idle,
  checking,
  upToDate,
  updateAvailable,
  error,
}

class AndroidUpdateService extends ChangeNotifier {
  static const Duration automaticCheckInterval = Duration(hours: 12);

  static const String websiteManifestUrl =
      'https://spicychatqol.drache.uk/android/manifest.json';
  static const String githubLatestReleaseUrl =
      'https://api.github.com/repos/drachescript/spicychat-qol-android/releases/latest';
  static const String androidDownloadPageUrl =
      'https://spicychatqol.drache.uk/android/';

  static const String _lastCheckedKey =
      'ds_android_native_update_last_checked_ms';

  static const MethodChannel _appInfoChannel =
      MethodChannel('uk.drache.spicychatqol/app_info');

  final AppLogService _appLog = AppLogService.instance;

  SharedPreferences? _prefs;
  bool _initialized = false;
  bool _checking = false;
  String _currentVersionName = 'unknown';
  int _currentVersionCode = 0;
  DateTime? _lastCheckedAt;
  AndroidUpdateInfo? _latest;
  AndroidUpdateStatus _status = AndroidUpdateStatus.idle;
  String? _errorMessage;

  bool _downloading = false;
  double? _downloadProgress;
  String? _installMessage;
  String? _downloadedApkPath;
  String? _downloadedVersionName;
  int? _downloadedVersionCode;

  bool get initialized => _initialized;
  bool get checking => _checking;
  String get currentVersionName => _currentVersionName;
  int get currentVersionCode => _currentVersionCode;
  DateTime? get lastCheckedAt => _lastCheckedAt;
  AndroidUpdateInfo? get latest => _latest;
  AndroidUpdateStatus get status => _status;
  String? get errorMessage => _errorMessage;

  bool get downloading => _downloading;
  double? get downloadProgress => _downloadProgress;
  String? get installMessage => _installMessage;

  bool get hasDownloadedApk {
    final path = _downloadedApkPath;
    final info = _latest;
    if (path == null || path.isEmpty || info == null) return false;

    if (info.versionCode != null && _downloadedVersionCode != null) {
      return info.versionCode == _downloadedVersionCode;
    }

    return info.versionName == _downloadedVersionName;
  }

  bool get automaticCheckDue {
    final last = _lastCheckedAt;
    return last == null ||
        DateTime.now().difference(last) >= automaticCheckInterval;
  }

  Duration? get automaticCheckRemaining {
    final last = _lastCheckedAt;
    if (last == null) return null;
    final elapsed = DateTime.now().difference(last);
    if (elapsed >= automaticCheckInterval) return Duration.zero;
    return automaticCheckInterval - elapsed;
  }

  bool get updateAvailable {
    final info = _latest;
    if (info == null) return false;

    final remoteCode = info.versionCode;
    if (remoteCode != null && remoteCode > 0 && _currentVersionCode > 0) {
      return remoteCode > _currentVersionCode;
    }

    return _compareVersions(info.versionName, _currentVersionName) > 0;
  }

  Future<void> init() async {
    if (_initialized) return;

    _prefs = await SharedPreferences.getInstance();

    final lastMs = _prefs?.getInt(_lastCheckedKey);
    if (lastMs != null && lastMs > 0) {
      _lastCheckedAt = DateTime.fromMillisecondsSinceEpoch(lastMs);
    }

    try {
      final raw = await _appInfoChannel.invokeMapMethod<String, dynamic>(
        'getAppInfo',
      );

      final versionName = (raw?['versionName'] ?? '').toString().trim();
      final versionCodeRaw = raw?['versionCode'];

      if (versionName.isNotEmpty) {
        _currentVersionName = versionName;
      }

      if (versionCodeRaw is int) {
        _currentVersionCode = versionCodeRaw;
      } else if (versionCodeRaw is num) {
        _currentVersionCode = versionCodeRaw.toInt();
      } else {
        _currentVersionCode =
            int.tryParse(versionCodeRaw?.toString() ?? '') ?? 0;
      }

      unawaited(
        _appLog.log(
          'AndroidUpdate',
          'Installed Android version: '
              '$_currentVersionName+$_currentVersionCode',
        ),
      );
    } catch (e, stackTrace) {
      unawaited(
        _appLog.log(
          'AndroidUpdate',
          'Could not read installed Android package version',
          level: 'WARN',
          error: e,
          stackTrace: stackTrace,
        ),
      );
    }

    _initialized = true;
    notifyListeners();
  }

  Future<bool> maybeCheckAutomatically() async {
    if (!_initialized) {
      await init();
    }

    if (_checking || !automaticCheckDue) {
      return false;
    }

    return checkForUpdates(manual: false);
  }

  Future<bool> checkForUpdates({bool manual = true}) async {
    if (!_initialized) {
      await init();
    }

    if (_checking) return false;

    if (!manual && !automaticCheckDue) {
      return false;
    }

    _checking = true;
    _status = AndroidUpdateStatus.checking;
    _errorMessage = null;
    _installMessage = null;
    notifyListeners();

    final candidates = <AndroidUpdateInfo>[];
    final errors = <String>[];

    AndroidUpdateInfo? websiteInfo;
    var websiteSucceeded = false;
    var githubSucceeded = false;

    try {
      final websiteJson = await _fetchJson(websiteManifestUrl);
      websiteSucceeded = true;
      websiteInfo = _fromWebsiteManifest(websiteJson);
      if (websiteInfo != null) {
        candidates.add(websiteInfo);
      }
    } catch (e) {
      errors.add('website: $e');
    }

    try {
      final releaseJson = await _fetchJson(githubLatestReleaseUrl);
      var githubInfo = _fromGitHubRelease(releaseJson);
      githubSucceeded = true;

      final metadataUrl = _githubUpdateMetadataUrl(releaseJson);
      if (metadataUrl != null) {
        try {
          final metadata = await _fetchJson(metadataUrl);
          final metadataInfo = _fromWebsiteManifest(
            metadata,
            source: 'GitHub release update.json',
          );

          if (metadataInfo != null) {
            githubInfo = githubInfo.copyWith(
              versionName: metadataInfo.versionName,
              versionCode: metadataInfo.versionCode,
              tag: metadataInfo.tag,
              apkUrl: metadataInfo.apkUrl ?? githubInfo.apkUrl,
              sha256: metadataInfo.sha256 ?? githubInfo.sha256,
              source: 'GitHub release + update.json',
            );
          }
        } catch (e) {
          unawaited(
            _appLog.log(
              'AndroidUpdate',
              'Latest release found, but update.json could not be read: $e',
              level: 'WARN',
            ),
          );
        }
      }

      candidates.add(githubInfo);
    } catch (e) {
      errors.add('GitHub: $e');
    }

    if (candidates.isEmpty) {
      _latest = null;
      _status = AndroidUpdateStatus.error;
      _errorMessage = errors.isEmpty
          ? 'No update source returned usable version information.'
          : 'Could not check for updates. ${errors.join(' | ')}';

      unawaited(
        _appLog.log(
          'AndroidUpdate',
          'Update check was inconclusive and will not consume the 12-hour '
              'cooldown: $_errorMessage',
          level: 'WARN',
        ),
      );

      _checking = false;
      notifyListeners();
      return false;
    }

    _latest = candidates.reduce(_newerInfo);

    final websiteConclusive = websiteSucceeded &&
        websiteInfo != null &&
        _compareInfoToInstalled(websiteInfo) >= 0;

    final anySourceFoundNewer =
        candidates.any((info) => _compareInfoToInstalled(info) > 0);

    final conclusive =
        githubSucceeded || websiteConclusive || anySourceFoundNewer;

    if (!conclusive) {
      _status = AndroidUpdateStatus.error;

      final sourceDetail = errors.isEmpty
          ? ''
          : ' ${errors.join(' | ')}';

      _errorMessage =
          'The website update information is older than this installed build '
          'and the latest GitHub release could not be verified. '
          'The automatic checker will retry instead of waiting 12 hours.'
          '$sourceDetail';

      unawaited(
        _appLog.log(
          'AndroidUpdate',
          'Degraded update check did not consume the 12-hour cooldown: '
              'installed=$_currentVersionName+$_currentVersionCode, '
              'website=${websiteInfo?.versionName ?? 'unavailable'}+'
              '${websiteInfo?.versionCode ?? '?'}, '
              'githubSucceeded=$githubSucceeded',
          level: 'WARN',
        ),
      );

      _checking = false;
      notifyListeners();
      return false;
    }

    _status = updateAvailable
        ? AndroidUpdateStatus.updateAvailable
        : AndroidUpdateStatus.upToDate;
    _errorMessage = null;

    _lastCheckedAt = DateTime.now();
    await _prefs?.setInt(
      _lastCheckedKey,
      _lastCheckedAt!.millisecondsSinceEpoch,
    );

    unawaited(
      _appLog.log(
        'AndroidUpdate',
        'Update check complete: installed='
            '$_currentVersionName+$_currentVersionCode, '
            'latest=${_latest!.versionName}+'
            '${_latest!.versionCode ?? '?'} '
            '(${_latest!.source}), '
            'updateAvailable=$updateAvailable, '
            'websiteSucceeded=$websiteSucceeded, '
            'githubSucceeded=$githubSucceeded',
      ),
    );

    _checking = false;
    notifyListeners();
    return true;
  }

  int _compareInfoToInstalled(AndroidUpdateInfo info) {
    final remoteCode = info.versionCode;
    if (remoteCode != null && remoteCode > 0 && _currentVersionCode > 0) {
      return remoteCode.compareTo(_currentVersionCode);
    }

    return _compareVersions(info.versionName, _currentVersionName);
  }

  String? _effectiveApkUrl(AndroidUpdateInfo info) {
    final explicit = info.apkUrl?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;

    final tag = info.tag.trim().isNotEmpty
        ? info.tag.trim()
        : 'v${info.versionName}';

    final filename = 'SpicyChat-QOL-Android-$tag.apk';
    return 'https://github.com/drachescript/spicychat-qol-android/'
        'releases/download/$tag/$filename';
  }

  Future<bool> downloadAndInstallLatestApk() async {
    if (!_initialized) {
      await init();
    }

    if (_downloading) return false;

    if (_latest == null) {
      await checkForUpdates(manual: true);
    }

    final info = _latest;
    if (info == null) {
      _errorMessage = 'Could not find the latest Android release.';
      _status = AndroidUpdateStatus.error;
      notifyListeners();
      return false;
    }

    if (!updateAvailable && !hasDownloadedApk) {
      _installMessage = 'You already have the latest Android app version.';
      notifyListeners();
      return false;
    }

    if (hasDownloadedApk) {
      return installDownloadedUpdate();
    }

    final apkUrl = _effectiveApkUrl(info);
    if (apkUrl == null || apkUrl.isEmpty) {
      _errorMessage = 'The latest release does not include an APK download.';
      _status = AndroidUpdateStatus.error;
      notifyListeners();
      return false;
    }

    _downloading = true;
    _downloadProgress = 0;
    _installMessage = 'Downloading update inside the app…';
    _errorMessage = null;
    notifyListeners();

    HttpClient? client;
    IOSink? sink;

    try {
      final cache = await getTemporaryDirectory();
      final safeTag = info.tag
          .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
          .replaceAll(RegExp(r'-+'), '-');
      final file = File(
        '${cache.path}${Platform.pathSeparator}'
        'SpicyChat-QOL-Android-${safeTag.isEmpty ? info.versionName : safeTag}.apk',
      );

      if (await file.exists()) {
        await file.delete();
      }

      client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..idleTimeout = const Duration(seconds: 30);

      final request = await client.getUrl(Uri.parse(apkUrl));
      request.followRedirects = true;
      request.maxRedirects = 8;
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'SpicyChat-QOL-Android/$_currentVersionName',
      );
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.android.package-archive,application/octet-stream,*/*',
      );

      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw HttpException(
          'APK download returned HTTP ${response.statusCode}.',
          uri: Uri.parse(apkUrl),
        );
      }

      final total = response.contentLength;
      var received = 0;
      var lastReported = -1;

      sink = file.openWrite();

      await for (final chunk in response.timeout(const Duration(seconds: 45))) {
        sink.add(chunk);
        received += chunk.length;

        if (total > 0) {
          final percent = ((received * 100) / total).floor().clamp(0, 100);
          if (percent != lastReported && (percent == 100 || percent % 2 == 0)) {
            lastReported = percent;
            _downloadProgress = percent / 100;
            notifyListeners();
          }
        }
      }

      await sink.flush();
      await sink.close();
      sink = null;

      if (!await file.exists() || await file.length() < 1024 * 1024) {
        throw const FormatException('Downloaded APK was missing or too small.');
      }

      _downloadedApkPath = file.path;
      _downloadedVersionName = info.versionName;
      _downloadedVersionCode = info.versionCode;
      _downloadProgress = 1;
      _installMessage = 'Download complete. Opening Android installer…';
      notifyListeners();

      unawaited(
        _appLog.log(
          'AndroidUpdate',
          'Downloaded update APK in-app: '
              '${info.versionName}+${info.versionCode ?? '?'} '
              '(${await file.length()} bytes)',
        ),
      );

      return await installDownloadedUpdate();
    } catch (e, stackTrace) {
      try {
        await sink?.close();
      } catch (_) {}

      _status = AndroidUpdateStatus.error;
      _errorMessage = 'Could not download the Android update: $e';
      _installMessage = null;

      unawaited(
        _appLog.log(
          'AndroidUpdate',
          'In-app APK download failed',
          level: 'ERROR',
          error: e,
          stackTrace: stackTrace,
        ),
      );

      return false;
    } finally {
      client?.close(force: true);
      _downloading = false;
      notifyListeners();
    }
  }

  Future<bool> installDownloadedUpdate() async {
    final info = _latest;
    final path = _downloadedApkPath;

    if (info == null || path == null || path.isEmpty) {
      return downloadAndInstallLatestApk();
    }

    final file = File(path);
    if (!await file.exists()) {
      _downloadedApkPath = null;
      _downloadedVersionName = null;
      _downloadedVersionCode = null;
      _installMessage = null;
      notifyListeners();
      return downloadAndInstallLatestApk();
    }

    try {
      final raw = await _appInfoChannel.invokeMapMethod<String, dynamic>(
        'installApk',
        <String, dynamic>{
          'path': file.path,
          'sha256': info.sha256 ?? '',
          'versionName': info.versionName,
          'versionCode': info.versionCode ?? 0,
        },
      );

      final ok = raw?['ok'] == true;
      final permissionRequired = raw?['permissionRequired'] == true;

      if (permissionRequired) {
        _installMessage =
            'Android needs permission to install updates from this app. '
            'Enable it on the screen that opened, come back here, then tap '
            'Install downloaded update.';
        notifyListeners();
        return false;
      }

      if (!ok) {
        final error = (raw?['error'] ?? 'Android installer could not be opened.')
            .toString();
        _status = AndroidUpdateStatus.error;
        _errorMessage = error;
        _installMessage = null;
        notifyListeners();
        return false;
      }

      _installMessage =
          'Android installer opened. Confirm the update to finish installing.';
      notifyListeners();
      return true;
    } on PlatformException catch (e, stackTrace) {
      _status = AndroidUpdateStatus.error;
      _errorMessage = e.message ?? 'Android installer could not be opened.';
      _installMessage = null;

      unawaited(
        _appLog.log(
          'AndroidUpdate',
          'Native APK install handoff failed',
          level: 'ERROR',
          error: e,
          stackTrace: stackTrace,
        ),
      );

      notifyListeners();
      return false;
    } catch (e, stackTrace) {
      _status = AndroidUpdateStatus.error;
      _errorMessage = 'Android installer could not be opened: $e';
      _installMessage = null;

      unawaited(
        _appLog.log(
          'AndroidUpdate',
          'Native APK install handoff failed',
          level: 'ERROR',
          error: e,
          stackTrace: stackTrace,
        ),
      );

      notifyListeners();
      return false;
    }
  }

  /// Kept for old call sites. "Open update" now means download the newest APK
  /// inside the app and hand it directly to Android's package installer.
  Future<bool> openLatestUpdatePage() => downloadAndInstallLatestApk();

  /// Kept for old call sites. No external browser/GitHub page is opened.
  Future<bool> openLatestApk() => downloadAndInstallLatestApk();

  Future<Map<String, dynamic>> _fetchJson(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);

    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'SpicyChat-QOL-Android/$_currentVersionName',
      );
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');

      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw HttpException(
          'HTTP ${response.statusCode} from $url',
          uri: Uri.parse(url),
        );
      }

      final body = await utf8.decoder.bind(response).join();
      final decoded = jsonDecode(body);

      if (decoded is! Map) {
        throw const FormatException('Update response was not a JSON object.');
      }

      return Map<String, dynamic>.from(decoded);
    } finally {
      client.close(force: true);
    }
  }

  AndroidUpdateInfo? _fromWebsiteManifest(
    Map<String, dynamic> json, {
    String source = 'website manifest',
  }) {
    if (json['available'] == false) return null;

    var versionName = (json['versionName'] ?? json['version'] ?? '')
        .toString()
        .trim();

    var tag = (json['tag'] ?? json['tagName'] ?? '').toString().trim();

    if (versionName.isEmpty && tag.isNotEmpty) {
      versionName = tag.replaceFirst(RegExp(r'^v', caseSensitive: false), '');
    }

    if (tag.isEmpty && versionName.isNotEmpty) {
      tag = 'v$versionName';
    }

    if (versionName.isEmpty) return null;

    final versionCode = _toInt(json['versionCode']);

    var releaseUrl = (json['releaseUrl'] ?? '').toString().trim();
    if (releaseUrl.isEmpty && tag.isNotEmpty) {
      releaseUrl =
          'https://github.com/drachescript/spicychat-qol-android/releases/tag/$tag';
    }
    if (releaseUrl.isEmpty) {
      releaseUrl = androidDownloadPageUrl;
    }

    final apkUrl = _nullableText(json['apkUrl'] ?? json['downloadUrl']);
    final sha256 = _nullableText(json['sha256']);

    return AndroidUpdateInfo(
      versionName: versionName,
      versionCode: versionCode,
      tag: tag,
      releaseUrl: releaseUrl,
      apkUrl: apkUrl,
      sha256: sha256,
      source: source,
    );
  }

  AndroidUpdateInfo _fromGitHubRelease(Map<String, dynamic> json) {
    final tag = (json['tag_name'] ?? '').toString().trim();
    final versionName =
        tag.replaceFirst(RegExp(r'^v', caseSensitive: false), '').trim();

    if (versionName.isEmpty) {
      throw const FormatException(
        'GitHub latest release did not contain a version tag.',
      );
    }

    final assets = json['assets'];
    String? apkUrl;

    if (assets is List) {
      for (final raw in assets) {
        if (raw is! Map) continue;
        final asset = Map<String, dynamic>.from(raw);
        final name = (asset['name'] ?? '').toString().toLowerCase();
        if (name.endsWith('.apk') && !name.contains('_old.apk')) {
          apkUrl = _nullableText(asset['browser_download_url']);
          if (apkUrl != null) break;
        }
      }
    }

    final releaseUrl =
        _nullableText(json['html_url']) ??
        'https://github.com/drachescript/spicychat-qol-android/releases/tag/$tag';

    return AndroidUpdateInfo(
      versionName: versionName,
      versionCode: null,
      tag: tag,
      releaseUrl: releaseUrl,
      apkUrl: apkUrl,
      sha256: null,
      source: 'GitHub latest release',
    );
  }

  String? _githubUpdateMetadataUrl(Map<String, dynamic> json) {
    final assets = json['assets'];
    if (assets is! List) return null;

    for (final raw in assets) {
      if (raw is! Map) continue;
      final asset = Map<String, dynamic>.from(raw);
      final name = (asset['name'] ?? '').toString().trim().toLowerCase();
      if (name == 'update.json') {
        return _nullableText(asset['browser_download_url']);
      }
    }

    return null;
  }

  AndroidUpdateInfo _newerInfo(
    AndroidUpdateInfo a,
    AndroidUpdateInfo b,
  ) {
    final aCode = a.versionCode;
    final bCode = b.versionCode;

    if (aCode != null && bCode != null && aCode != bCode) {
      return aCode > bCode ? a : b;
    }

    return _compareVersions(a.versionName, b.versionName) >= 0 ? a : b;
  }

  static int _compareVersions(String a, String b) {
    final aParts = _versionParts(a);
    final bParts = _versionParts(b);
    final length = aParts.length > bParts.length
        ? aParts.length
        : bParts.length;

    for (var i = 0; i < length; i++) {
      final av = i < aParts.length ? aParts[i] : 0;
      final bv = i < bParts.length ? bParts[i] : 0;
      if (av != bv) return av.compareTo(bv);
    }

    return 0;
  }

  static List<int> _versionParts(String value) {
    final clean = value
        .trim()
        .replaceFirst(RegExp(r'^v', caseSensitive: false), '')
        .split('+')
        .first
        .split('-')
        .first;

    return clean
        .split('.')
        .map((part) => int.tryParse(part) ?? 0)
        .toList();
  }

  static int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static String? _nullableText(dynamic value) {
    final text = (value ?? '').toString().trim();
    return text.isEmpty ? null : text;
  }
}
