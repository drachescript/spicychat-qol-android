import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

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

  bool get initialized => _initialized;
  bool get checking => _checking;
  String get currentVersionName => _currentVersionName;
  int get currentVersionCode => _currentVersionCode;
  DateTime? get lastCheckedAt => _lastCheckedAt;
  AndroidUpdateInfo? get latest => _latest;
  AndroidUpdateStatus get status => _status;
  String? get errorMessage => _errorMessage;

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

    // A failed/degraded network check must not count as a completed automatic
    // check. Returning the real result also prevents startup UI from treating
    // an inconclusive attempt as successful.
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
          // The release itself is still enough for semantic-version checking.
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

    // The website copy can briefly lag behind a just-published GitHub release.
    // If GitHub itself could not be reached, an older website manifest must not
    // be treated as proof that this installation is current. In that degraded
    // case we leave lastCheckedAt untouched so the next launch retries instead
    // of suppressing checks for another 12 hours.
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

    // "Last checked" means last successful/conclusive check, not merely the
    // last network attempt. This is the timestamp used by the 12-hour gate.
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

  Future<bool> openLatestUpdatePage() async {
    final info = _latest;
    final target = info != null && info.releaseUrl.trim().isNotEmpty
        ? info.releaseUrl
        : androidDownloadPageUrl;

    final uri = Uri.tryParse(target);
    if (uri == null) return false;

    return launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
  }

  Future<bool> openLatestApk() async {
    final apk = _latest?.apkUrl?.trim();
    if (apk == null || apk.isEmpty) {
      return openLatestUpdatePage();
    }

    final uri = Uri.tryParse(apk);
    if (uri == null) return openLatestUpdatePage();

    return launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
  }

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
        if (name.endsWith('.apk')) {
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
