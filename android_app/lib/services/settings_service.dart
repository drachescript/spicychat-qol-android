import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/settings.dart';

// DS_ANDROID_QOL_299_RECORD_COUNTS_V1: worker-isolate count-only snapshot.
Map<String, int> _countQolRecords(Map<String, Object?> snapshots) {
  final result = <String, int>{};
  for (final entry in snapshots.entries) {
    final raw = entry.value;
    if (raw == null) {
      result[entry.key] = 0;
      continue;
    }
    final decoded = raw is String ? jsonDecode(raw) : raw;
    if (decoded is! Map) {
      throw const FormatException('Unsupported saved-record store');
    }
    final meta = decoded['meta'];
    final records = meta is Map ? meta : decoded;
    final ids = <String>{};
    for (final record in records.entries) {
      if (record.value is! Map) continue;
      final id = record.key.toString().trim();
      if (id.isNotEmpty) ids.add(id);
    }
    result[entry.key] = ids.length;
  }
  return result;
}

// DS_ANDROID_STORAGE_PRESSURE_V1: send only requested records. Do not cache
// an additional decoded archive or return an empty result on malformed data.
String projectNativeStorageRecords(Map<String, dynamic> input) {
  final raw = input['raw'];
  final decoded = raw is String ? jsonDecode(raw) : raw;
  if (decoded != null && decoded is! Map) {
    throw const FormatException('Invalid native record store');
  }
  final source = (decoded as Map?) ?? const <String, dynamic>{};
  final meta = source['meta'];
  final records = meta is Map ? meta : source;
  final result = <String, dynamic>{};
  for (final id in input['ids'] as List<String>) {
    final row = records[id];
    if (row is Map) result[id] = row;
  }
  return jsonEncode({'ok': true, 'records': result});
}

// Same decoding/default semantics as storageGet, with large conversions kept
// off the Flutter UI isolate. Only the serialized response crosses back.
String projectNativeStorageJson(Map<String, dynamic> input) {
  final result = <String, dynamic>{};
  for (final entry in (input['raw'] as Map<String, Object?>).entries) {
    final raw = entry.value;
    if (raw is String) {
      try {
        result[entry.key] = jsonDecode(raw);
      } catch (_) {
        result[entry.key] = raw;
      }
    } else {
      result[entry.key] = raw;
    }
  }
  result.addAll(input['defaults'] as Map<String, dynamic>);
  return jsonEncode(result);
}

// DS_ANDROID_RECORD_MERGE_V2: preserve the existing JSON envelope and metadata.
// These top-level worker functions do not access Flutter services.
String? mergeNativeStorageRecords(Map<String, dynamic> input) {
  final raw = input['raw'];
  final decoded = raw is String ? jsonDecode(raw) : raw;
  if (decoded != null && decoded is! Map) {
    throw const FormatException('Invalid saved record store');
  }
  final source = Map<String, dynamic>.from((decoded as Map?) ?? {});
  if (source.containsKey('meta') && source['meta'] is! Map) {
    throw const FormatException('Invalid saved record metadata');
  }
  final hasMeta = source['meta'] is Map;
  final records = Map<String, dynamic>.from(hasMeta ? source['meta'] as Map : source);
  final updates = input['entries'] as Map;
  if (updates.length > 10000) throw const FormatException('Too many records');
  var changed = false;
  for (final entry in updates.entries) {
    final id = entry.key;
    if (id is! String || id.isEmpty || id.trim() != id || id.length > 256 ||
        const ['__proto__', 'prototype', 'constructor'].contains(id) || entry.value is! Map) {
      throw const FormatException('Invalid record update');
    }
    if (jsonEncode(records[id]) == jsonEncode(entry.value)) continue;
    records[id] = entry.value;
    changed = true;
  }
  if (!changed) return null;
  return jsonEncode(<String, dynamic>{if (hasMeta) ...source, 'meta': records});
}

// POSIX rename replaces the destination atomically on Android. Never unlink
// the last committed file before the new envelope has been flushed.
bool writeNativeLargeEnvelope(Map<String, String> input) {
  final target = File(input['path']!);
  final temp = File('${target.path}.tmp');
  try {
    temp.writeAsStringSync(jsonEncode(<String, String>{
      'key': input['key']!, 'value': input['value']!,
    }), flush: true);
    temp.renameSync(target.path);
    return true;
  } finally {
    if (temp.existsSync()) temp.deleteSync();
  }
}

// Count UTF-8 without constructing a second full-size byte array. Match Dart's
// UTF-8 replacement behavior for unpaired UTF-16 surrogates.
int nativeUtf8Length(String text) {
  var count = 0;
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit < 0x80) {
      count++;
    } else if (unit < 0x800) {
      count += 2;
    } else if (unit >= 0xd800 && unit <= 0xdbff && i + 1 < text.length &&
        text.codeUnitAt(i + 1) >= 0xdc00 && text.codeUnitAt(i + 1) <= 0xdfff) {
      count += 4;
      i++;
    } else {
      count += 3;
    }
  }
  return count;
}

Map<String, int> countNativeStorageBytes(Map<String, Object?> values) {
  return <String, int>{
    for (final entry in values.entries)
      entry.key: nativeUtf8Length(entry.key) + nativeUtf8Length(
        entry.value is String ? entry.value as String : jsonEncode(entry.value)),
  };
}

// DS_ANDROID_QOL_032_LARGE_PROTOCOL_V1: explicit whole-store operations.
// Preserve the current file format; no desktop IndexedDB migration.
Map<String, dynamic> nativeLargeEnvelope(Object? raw) {
  final decoded = raw is String ? jsonDecode(raw) : raw;
  if (raw == null) return <String, dynamic>{'meta': <String, dynamic>{}};
  if (decoded is! Map || (decoded.containsKey('meta') && decoded['meta'] is! Map)) {
    throw const FormatException('Invalid native large store');
  }
  final source = Map<String, dynamic>.from(decoded);
  return source['meta'] is Map ? source : <String, dynamic>{'meta': source};
}

String readNativeLargeValues(Map<String, Object?> raw) => jsonEncode({
  'ok': true,
  'data': {for (final entry in raw.entries) entry.key: nativeLargeEnvelope(entry.value)},
});

Map<String, String> encodeNativeLargeReplacements(Map<String, dynamic> values) {
  final result = <String, String>{};
  for (final entry in values.entries) {
    if (entry.value is! Map) throw const FormatException('Invalid replacement');
    final envelope = nativeLargeEnvelope(entry.value);
    final records = envelope['meta'] as Map;
    if (records.entries.any((row) => row.key is! String ||
        (row.key as String).trim().isEmpty || row.value is! Map)) {
      throw const FormatException('Invalid replacement record');
    }
    result[entry.key] = jsonEncode(envelope);
  }
  return result;
}

({String? encoded, int removed, int count}) removeNativeLargeRecords(
    Map<String, dynamic> input) {
  final envelope = nativeLargeEnvelope(input['raw']);
  final records = Map<String, dynamic>.from(envelope['meta'] as Map);
  var removed = 0;
  for (final id in input['ids'] as List<String>) {
    if (records[id] is Map) {
      records.remove(id);
      removed++;
    }
  }
  return (encoded: removed == 0 ? null : jsonEncode({...envelope, 'meta': records}),
      removed: removed, count: records.values.whereType<Map>().length);
}

/// Persistent storage backing the Android chrome.storage.local bridge.
///
/// Small values stay in SharedPreferences. Larger JSON/string values use one
/// private file per storage key so QoL features with revision history do not
/// force Android to rewrite a huge SharedPreferences XML file on every save.
/// This matters for QoL 9's Backup Manager (10+ revisions per bot, manual
/// checkpoints, profile snapshots), Lorebook backups, Storydate and RP State.
class SettingsService extends ChangeNotifier {
  static const _settingsKey = 'settings';
  static const _largeValueThresholdBytes = 32 * 1024;
  static const _largeStorageFolder = 'qol_large_storage_v1';
  // Account/device credentials are intentionally device-local and must never
  // be copied into ordinary QoL backup files.
  static const _qolSyncPrivateBackupKeys = <String>{
    'qolSyncAuthV1',
    'qolSyncStateV1',
  };

  SharedPreferences? _prefs;
  Directory? _largeStorageDir;
  final Map<String, String> _largeStringValues = <String, String>{};
  final Map<String, Object?> _memoryFallback = <String, Object?>{};
  AppSettings _settings = AppSettings();
  // DS_ANDROID_QOL_299_RECORD_COUNTS_V1: cache only counts and current raw
  // references; writes/removals invalidate the affected key, never stored data.
  static const _countableQolStores = <String>{
    'botArchive', 'botAvailability', 'lorebookStatus',
  };
  final _qolCountCache = <String, (Object?, int)>{};

  AppSettings get settings => _settings;
  bool get persistentStorageAvailable => _prefs != null;
  bool get largeStorageAvailable => _largeStorageDir != null;
  int get largeStorageKeyCount => _largeStringValues.length;

  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (e, stackTrace) {
      debugPrint('[SettingsService] SharedPreferences init failed: $e');
      debugPrintStack(stackTrace: stackTrace);
      _prefs = null;
    }

    await _initLargeStorage();
    await _migrateExistingLargeStrings();
    _loadSettings();
  }

  Future<void> _initLargeStorage() async {
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/$_largeStorageFolder');
      await dir.create(recursive: true);
      _largeStorageDir = dir;

      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final raw = await entity.readAsString();
          final decoded = jsonDecode(raw);
          if (decoded is! Map) continue;
          final key = decoded['key']?.toString() ?? '';
          final value = decoded['value'];
          if (key.isEmpty || value is! String) continue;
          _largeStringValues[key] = value;
        } catch (e) {
          debugPrint(
            '[SettingsService] Ignoring unreadable large-storage file '
            '${entity.path}: $e',
          );
        }
      }

      // Stale temp files are safe to discard after startup.
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.tmp')) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (e, stackTrace) {
      debugPrint('[SettingsService] Large-storage init failed: $e');
      debugPrintStack(stackTrace: stackTrace);
      _largeStorageDir = null;
      _largeStringValues.clear();
    }
  }

  String _hashKey(String key) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(key)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  String _largeFilenameForKey(String key) {
    final encoded = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
    final safe = encoded.length <= 120
        ? encoded
        : '${encoded.substring(0, 96)}-${_hashKey(key)}';
    return '$safe.json';
  }

  File? _largeFileForKey(String key) {
    final dir = _largeStorageDir;
    if (dir == null) return null;
    return File('${dir.path}/${_largeFilenameForKey(key)}');
  }

  bool _shouldUseLargeStorage(Object? value) {
    return value is String &&
        (value.length >= _largeValueThresholdBytes ||
            (value.length * 3 >= _largeValueThresholdBytes &&
                nativeUtf8Length(value) >= _largeValueThresholdBytes));
  }

  Future<bool> _storeLargeString(String key, String value) async {
    final file = _largeFileForKey(key);
    if (file == null) return false;

    try {
      await _projectInOrder(() => compute(writeNativeLargeEnvelope, <String, String>{
        'path': file.path, 'key': key, 'value': value,
      }));

      _largeStringValues[key] = value;
      _memoryFallback.remove(key);
      try {
        await _prefs?.remove(key);
      } catch (_) {}
      return true;
    } catch (e) {
      debugPrint('[SettingsService] Large-storage write failed for "$key": $e');
      return false;
    }
  }

  Future<void> _removeLargeValue(String key) async {
    _largeStringValues.remove(key);
    final file = _largeFileForKey(key);
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('[SettingsService] Could not delete large value "$key": $e');
    }
  }

  Future<void> _migrateExistingLargeStrings() async {
    final prefs = _prefs;
    if (prefs == null || _largeStorageDir == null) return;

    List<String> keys;
    try {
      keys = prefs.getKeys().toList(growable: false);
    } catch (_) {
      return;
    }

    var migrated = 0;
    for (final key in keys) {
      if (_largeStringValues.containsKey(key)) continue;
      Object? raw;
      try {
        raw = prefs.get(key);
      } catch (_) {
        continue;
      }
      if (!_shouldUseLargeStorage(raw)) continue;
      if (await _storeLargeString(key, raw as String)) migrated++;
    }

    if (migrated > 0) {
      debugPrint(
        '[SettingsService] Migrated $migrated large chrome.storage values '
        'out of SharedPreferences.',
      );
    }
  }

  Object? _rawGet(String key) {
    if (_largeStringValues.containsKey(key)) {
      return _largeStringValues[key];
    }

    try {
      return _prefs?.get(key) ?? _memoryFallback[key];
    } catch (e) {
      debugPrint('[SettingsService] Could not read "$key": $e');
      return _memoryFallback[key];
    }
  }

  Set<String> _allKeys() {
    try {
      return <String>{
        ...?_prefs?.getKeys(),
        ..._largeStringValues.keys,
        ..._memoryFallback.keys,
      };
    } catch (_) {
      return <String>{
        ..._largeStringValues.keys,
        ..._memoryFallback.keys,
      };
    }
  }

  void _loadSettings() {
    try {
      final raw = _rawGet(_settingsKey);

      if (raw == null) {
        _settings = AppSettings();
      } else if (raw is String && raw.trim().isNotEmpty) {
        _settings = AppSettings.fromJsonString(raw);
      } else {
        debugPrint(
          '[SettingsService] Ignoring unsupported legacy settings value '
          'of type ${raw.runtimeType}. Raw value is preserved.',
        );
        _settings = AppSettings();
      }
    } catch (e, stackTrace) {
      debugPrint('[SettingsService] Could not parse native settings model: $e');
      debugPrintStack(stackTrace: stackTrace);
      _settings = AppSettings();
    }

    notifyListeners();
  }

  Future<void> _writePrefsValue(String key, Object? value) async {
    final prefs = _prefs;
    if (prefs == null) {
      _memoryFallback[key] = value;
      return;
    }

    if (value is String) {
      await prefs.setString(key, value);
    } else if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is int) {
      await prefs.setInt(key, value);
    } else if (value is double) {
      await prefs.setDouble(key, value);
    } else if (value is List<String>) {
      await prefs.setStringList(key, value);
    } else if (value == null) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, jsonEncode(value));
    }
    _memoryFallback.remove(key);
  }

  Future<void> _setRaw(String key, Object? value) async {
    _qolCountCache.remove(key);
    _nativeByteCounts.remove(key);
    if (value == null) {
      await _removeRaw(key);
      return;
    }

    if (_shouldUseLargeStorage(value)) {
      if (await _storeLargeString(key, value as String)) return;
      // Native file storage failed; keep the newest value in SharedPreferences
      // or memory rather than losing a backup/checkpoint write.
    }

    try {
      await _writePrefsValue(key, value);
      // Only discard the previous large copy after the replacement value has
      // been committed to the small-value backend.
      if (_largeStringValues.containsKey(key)) {
        await _removeLargeValue(key);
      }
    } catch (e) {
      debugPrint('[SettingsService] Falling back to memory for "$key": $e');
      _memoryFallback[key] = value;
    }
  }

  Future<void> _removeRaw(String key) async {
    _qolCountCache.remove(key);
    _nativeByteCounts.remove(key);
    _memoryFallback.remove(key);
    await _removeLargeValue(key);
    try {
      await _prefs?.remove(key);
    } catch (e) {
      debugPrint('[SettingsService] Could not remove "$key": $e');
    }
  }

  dynamic _decodeStoredValue(Object? raw) {
    if (raw is! String) return raw;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw;
    }
  }

  List<String>? _requestedKeys(dynamic keys) {
    if (keys == null) return null;
    if (keys is String) return <String>[keys];
    if (keys is List) return keys.map((value) => value.toString()).toList();
    if (keys is Map) return keys.keys.map((value) => value.toString()).toList();
    return <String>[];
  }

  Future<void> saveSettings(AppSettings newSettings) => _mutateInOrder(() async {
    _settings = newSettings;
    await _setRaw(_settingsKey, newSettings.toJsonString());
    notifyListeners();
  });

  Future<Map<String, dynamic>> storageGet(dynamic keys) async {
    final result = <String, dynamic>{};
    final requested = _requestedKeys(keys);
    final keyList = requested ?? (_allKeys().toList()..sort());

    for (final key in keyList) {
      final raw = _rawGet(key);
      if (raw != null) {
        result[key] = _decodeStoredValue(raw);
      } else if (keys is Map && keys.containsKey(key)) {
        result[key] = keys[key];
      }
    }

    return result;
  }

  // Share a serial lane across Options and main WebView projections. A second
  // large decode must not compete for heap with the first. No cache or writes.
  Future<void> _projectionTail = Future<void>.value();

  Future<T> _projectInOrder<T>(Future<T> Function() task) {
    final result = Completer<T>();
    _projectionTail = _projectionTail.then((_) async {
      try {
        result.complete(await task());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<({String response, int keyCount})> storageGetJson(dynamic keys) async {
      final raw = <String, Object?>{};
      final defaults = <String, dynamic>{};
      final requested = _requestedKeys(keys);
      final keyList = requested ?? (_allKeys().toList()..sort());
      var chars = 0;
      for (final key in keyList) {
        final value = _rawGet(key);
        if (value != null) {
          raw[key] = value;
          if (value is String) chars += value.length;
        } else if (keys is Map && keys.containsKey(key)) {
          defaults[key] = keys[key];
        }
      }
      final input = <String, dynamic>{'raw': raw, 'defaults': defaults};
      final response = chars >= 128 * 1024
          ? await _projectInOrder(() => compute(projectNativeStorageJson, input))
          : projectNativeStorageJson(input);
      return (response: response, keyCount: raw.length + defaults.length);
  }

  Future<String> storageLargeRecordsJson(dynamic key, dynamic ids) {
    return _projectInOrder(() async {
      if (key is! String || !_countableQolStores.contains(key) || ids is! List) {
        throw const FormatException('Invalid native record request');
      }
      final clean = ids.whereType<String>().map((id) => id.trim())
          .where((id) => id.isNotEmpty).toSet().toList(growable: false);
      if (clean.length > 10000) {
        throw const FormatException('Record request too large');
      }
      final raw = _rawGet(key);
      if (raw == null) {
        final file = _largeFileForKey(key);
        if (_prefs == null || file == null || await file.exists()) {
          throw StateError('Native record storage unavailable');
        }
      }
      final input = <String, dynamic>{'raw': raw, 'ids': clean};
      return compute(projectNativeStorageRecords, input);
    });
  }

  // DS_ANDROID_QOL_299_RECORD_COUNTS_V1: no storage writes or migrations.
  // Read the raw native snapshot, count on a worker isolate and return numbers
  // only. Android stores JSON blobs, not the desktop IndexedDB record index.
  Future<Map<String, int>> storageLargeRecordStats(dynamic keys) async {
    final requested = (_requestedKeys(keys) ?? _countableQolStores.toList())
        .where(_countableQolStores.contains).toSet();
    final counts = <String, int>{};
    final pending = <String, Object?>{};
    for (final key in requested) {
      // An unreadable/missing backing store must not be reported as empty.
      final prefs = _prefs;
      final dir = _largeStorageDir;
      if (prefs == null || dir == null) {
        throw StateError('Native record storage unavailable');
      }
      final Object? raw;
      if (_largeStringValues.containsKey(key)) {
        raw = _largeStringValues[key];
      } else {
        if (await _largeFileForKey(key)!.exists() &&
            !_largeStringValues.containsKey(key)) {
          throw StateError('Saved-record file unavailable');
        }
        raw = _largeStringValues[key] ?? prefs.get(key) ?? _memoryFallback[key];
      }
      final cached = _qolCountCache[key];
      if (cached != null && identical(cached.$1, raw)) {
        counts[key] = cached.$2;
      } else {
        pending[key] = raw;
      }
    }
    if (pending.isNotEmpty) {
      final fresh = await _projectInOrder(() => compute(_countQolRecords, pending));
      for (final entry in fresh.entries) {
        final raw = pending[entry.key];
        // Do not cache a count if the underlying value changed while counting.
        if (identical(_rawGet(entry.key), raw)) {
          _qolCountCache[entry.key] = (raw, entry.value);
        }
        counts[entry.key] = entry.value;
      }
    }
    return counts;
  }

  Future<List<String>> storageGetKeys() async {
    final keys = _allKeys().toList()..sort();
    return keys;
  }

  Future<void> storageSet(Map<String, dynamic> obj) =>
      _mutateInOrder(() => _storageSetUnlocked(obj));

  Future<void> _storageSetUnlocked(Map<String, dynamic> obj) async {
    for (final entry in obj.entries) {
      final value = entry.value;
      if (value is String) {
        await _setRaw(entry.key, value);
      } else {
        await _setRaw(entry.key, jsonEncode(value));
      }
    }

    if (obj.containsKey(_settingsKey)) {
      _loadSettings();
    } else {
      notifyListeners();
    }
  }

  // DS_ANDROID_STORAGE_FASTPATH_V060: the WebView needs the same onChanged
  // payload as Chrome, but it no longer needs a separate native read to get it.
  // Read the committed values back: large-value fallbacks and JSON decoding
  // remain handled by the existing storage backend.
  // DS_ANDROID_V061_STORAGE_ORDER: keep the read/write/read operation atomic
  // relative to other WebView fast-path writes. Overlapping updates could make
  // the reported oldValue/newValue pair refer to a different write. Every
  // operation stays asynchronous, and a rejected write cannot poison the queue.
  Future<void> _pendingWebStorageDelta = Future<void>.value();
  final _nativeByteCounts = <String, (Object, int)>{};

  // All ordinary storage mutations and record merges share the same lane.
  // A read-modify-write merge cannot overwrite a concurrent Options write.
  Future<T> _mutateInOrder<T>(Future<T> Function() task) {
    final result = Completer<T>();
    _pendingWebStorageDelta = _pendingWebStorageDelta.then((_) async {
      try {
        result.complete(await task());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  // DS_ANDROID_QOL_032_LARGE_PROTOCOL_V1: all explicit large-store writes
  // share the existing mutation lane and committed-file replacement.
  List<String> _nativeLargeKeys(dynamic keys) {
    return (_requestedKeys(keys) ?? _countableQolStores.toList())
        .where(_countableQolStores.contains).toSet().toList(growable: false);
  }

  Future<Object?> _checkedNativeLargeRaw(String key) async {
    if (_prefs == null || _largeStorageDir == null) {
      throw StateError('Native record storage unavailable');
    }
    if (!_largeStringValues.containsKey(key) && await _largeFileForKey(key)!.exists()) {
      throw StateError('Saved record file unavailable');
    }
    return _rawGet(key);
  }

  Future<String> storageLargeValuesJson(dynamic keys) => _projectInOrder(() async {
    final raw = <String, Object?>{};
    for (final key in _nativeLargeKeys(keys)) {
      raw[key] = await _checkedNativeLargeRaw(key);
    }
    return compute(readNativeLargeValues, raw);
  });

  Future<void> _commitNativeLargeReplacement(String key, String encoded) async {
    final previous = await _checkedNativeLargeRaw(key);
    if (previous == encoded) return;
    if (!await _storeLargeString(key, encoded)) {
      throw StateError('Native large store commit failed');
    }
    _qolCountCache.remove(key);
    _nativeByteCounts.remove(key);
  }

  Future<Map<String, dynamic>> storageLargeReplace(dynamic values) =>
      _mutateInOrder(() async {
    if (values is! Map || values.keys.any((key) => !_countableQolStores.contains(key))) {
      throw const FormatException('Invalid native large store request');
    }
    final input = Map<String, dynamic>.from(values);
    // Validate every requested store before committing any replacement.
    for (final key in input.keys) {
      await _checkedNativeLargeRaw(key);
    }
    final encoded = await _projectInOrder(() => compute(encodeNativeLargeReplacements, input));
    final committed = <String>[];
    try {
      for (final entry in encoded.entries) {
        await _commitNativeLargeReplacement(entry.key, entry.value);
        committed.add(entry.key);
      }
    } catch (_) {
      if (committed.isNotEmpty) notifyListeners();
      return <String, dynamic>{'ok': false, 'keys': committed,
        'error': 'Native replacement incomplete; review committed stores before retrying'};
    }
    if (committed.isNotEmpty) notifyListeners();
    return <String, dynamic>{'ok': true, 'keys': committed};
  });

  Future<Map<String, dynamic>> storageLargeRemoveRecords(dynamic key, dynamic ids) =>
      _mutateInOrder(() async {
    if (key is! String || !_countableQolStores.contains(key) || ids is! List ||
        ids.length > 10000 || ids.any((id) => id is! String || id.trim().isEmpty)) {
      throw const FormatException('Invalid native record removal');
    }
    final clean = ids.cast<String>().map((id) => id.trim()).toSet().toList();
    final raw = await _checkedNativeLargeRaw(key);
    final result = await _projectInOrder(() => compute(removeNativeLargeRecords,
        <String, dynamic>{'raw': raw, 'ids': clean}));
    final encoded = result.encoded;
    if (encoded != null) {
      await _commitNativeLargeReplacement(key, encoded);
      notifyListeners();
    }
    return <String, dynamic>{'ok': true, 'key': key, 'removed': result.removed,
      'count': result.count};
  });

  Future<Map<String, dynamic>> storageLargeClear(dynamic keys) {
    // Unlike GET/STATS, an absent key list is not authorization to clear all.
    if (keys == null) throw const FormatException('Explicit store keys required');
    return storageLargeReplace({
      for (final key in _nativeLargeKeys(keys)) key: <String, dynamic>{'meta': <String, dynamic>{}},
    });
  }

  Future<Map<String, dynamic>> storageLargeMerge(dynamic key, dynamic entries) =>
      _mutateInOrder(() async {
    if (key is! String || !_countableQolStores.contains(key) || entries is! Map ||
        entries.length > 10000 || _prefs == null || _largeStorageDir == null) {
      throw const FormatException('Native record merge unavailable');
    }
    final raw = _rawGet(key);
    if (raw == null && await _largeFileForKey(key)!.exists()) {
      throw StateError('Saved record file could not be read');
    }
    final String? merged;
    try {
      merged = await _projectInOrder(() => compute(mergeNativeStorageRecords,
          <String, dynamic>{'raw': raw, 'entries': entries}));
    } catch (_) {
      throw const FormatException('Native record merge validation failed');
    }
    if (merged == null) return <String, dynamic>{'ok': true, 'changed': false};
    // A protected merge must not fall back to memory or SharedPreferences.
    if (!await _storeLargeString(key, merged)) {
      throw StateError('Native record merge could not be committed');
    }
    _qolCountCache.remove(key);
    _nativeByteCounts.remove(key);
    notifyListeners();
    return <String, dynamic>{'ok': true, 'changed': true};
  });

  Future<Map<String, dynamic>> storageSetWithChanges(
    Map<String, dynamic> obj,
  ) {
    if (obj.isEmpty) return Future<Map<String, dynamic>>.value(<String, dynamic>{});
    final result = Completer<Map<String, dynamic>>();
    _pendingWebStorageDelta = _pendingWebStorageDelta.then((_) async {
      try {
        final keys = obj.keys.toList(growable: false);
        final before = await storageGet(keys);
        await _storageSetUnlocked(obj);
        final after = await storageGet(keys);
        final changes = <String, dynamic>{};
        for (final key in keys) {
          final previous = before[key];
          final current = after[key];
          if (jsonEncode(previous) == jsonEncode(current)) continue;
          changes[key] = <String, dynamic>{
            'oldValue': previous,
            'newValue': current,
          };
        }
        result.complete(changes);
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  Future<void> storageRemove(dynamic keys) => _mutateInOrder(() async {
    final keyList = _requestedKeys(keys) ?? const <String>[];

    for (final key in keyList) {
      await _removeRaw(key);
    }

    if (keyList.contains(_settingsKey)) {
      _loadSettings();
    } else if (keyList.isNotEmpty) {
      notifyListeners();
    }
  });

  Future<void> storageClear() => _mutateInOrder(() async {
    final keys = _allKeys().toList(growable: false);
    for (final key in keys) {
      await _removeRaw(key);
    }
    _loadSettings();
  });

  Future<int> storageGetBytesInUse(dynamic keys) => _projectInOrder(() async {
    final requested = _requestedKeys(keys);
    final keyList = (requested ?? _allKeys().toList()).toSet();
    final pending = <String, Object?>{};
    var total = 0;
    var chars = 0;
    for (final key in keyList) {
      final raw = _rawGet(key);
      if (raw == null) continue;
      final cached = _nativeByteCounts[key];
      if (cached != null && identical(cached.$1, raw)) {
        total += cached.$2;
      } else {
        pending[key] = raw;
        chars += raw is String ? raw.length : 0;
      }
    }
    final fresh = chars >= 128 * 1024
        ? await compute(countNativeStorageBytes, pending)
        : countNativeStorageBytes(pending);
    for (final entry in fresh.entries) {
      final raw = pending[entry.key]!;
      if (identical(_rawGet(entry.key), raw)) {
        _nativeByteCounts[entry.key] = (raw, entry.value);
      }
      total += entry.value;
    }
    return total;
  });

  Map<String, dynamic> getAllStorageAsJson() {
    final result = <String, dynamic>{};
    for (final key in _allKeys()) {
      final raw = _rawGet(key);
      if (raw != null) {
        result[key] = _decodeStoredValue(raw);
      }
    }
    return result;
  }

  Map<String, Object?> _getRawSnapshot() {
    final result = <String, Object?>{};
    for (final key in _allKeys()) {
      result[key] = _rawGet(key);
    }
    return result;
  }

  Future<void> _restoreRawSnapshot(Map<String, Object?> snapshot) async {
    for (final key in _allKeys().toList()) {
      if (!snapshot.containsKey(key)) {
        await _removeRaw(key);
      }
    }

    for (final entry in snapshot.entries) {
      await _setRaw(entry.key, entry.value);
    }
  }

  String exportFullBackup() {
    final backup = getAllStorageAsJson()
      ..removeWhere((key, _) => _qolSyncPrivateBackupKeys.contains(key));
    return jsonEncode(backup);
  }

  Future<void> importFullBackup(Map<String, dynamic> backup) => _mutateInOrder(() async {
    final before = _getRawSnapshot();

    try {
      for (final entry in backup.entries) {
        if (_qolSyncPrivateBackupKeys.contains(entry.key)) continue;
        final value = entry.value;
        if (value is String) {
          await _setRaw(entry.key, value);
        } else {
          await _setRaw(entry.key, jsonEncode(value));
        }
      }
      _loadSettings();
    } catch (_) {
      await _restoreRawSnapshot(before);
      _loadSettings();
      rethrow;
    }
  });
}
