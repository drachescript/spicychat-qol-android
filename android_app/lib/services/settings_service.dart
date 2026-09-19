import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/settings.dart';

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

  SharedPreferences? _prefs;
  Directory? _largeStorageDir;
  final Map<String, String> _largeStringValues = <String, String>{};
  final Map<String, Object?> _memoryFallback = <String, Object?>{};
  AppSettings _settings = AppSettings();

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
        utf8.encode(value).length >= _largeValueThresholdBytes;
  }

  Future<bool> _storeLargeString(String key, String value) async {
    final file = _largeFileForKey(key);
    if (file == null) return false;

    final temp = File('${file.path}.tmp');
    try {
      final envelope = jsonEncode(<String, dynamic>{
        'key': key,
        'value': value,
      });
      await temp.writeAsString(envelope, flush: true);

      if (await file.exists()) {
        await file.delete();
      }
      await temp.rename(file.path);

      _largeStringValues[key] = value;
      _memoryFallback.remove(key);
      try {
        await _prefs?.remove(key);
      } catch (_) {}
      return true;
    } catch (e) {
      debugPrint('[SettingsService] Large-storage write failed for "$key": $e');
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
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

  Future<void> saveSettings(AppSettings newSettings) async {
    _settings = newSettings;
    await _setRaw(_settingsKey, newSettings.toJsonString());
    notifyListeners();
  }

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

  Future<List<String>> storageGetKeys() async {
    final keys = _allKeys().toList()..sort();
    return keys;
  }

  Future<void> storageSet(Map<String, dynamic> obj) async {
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

  Future<void> storageRemove(dynamic keys) async {
    final keyList = _requestedKeys(keys) ?? const <String>[];

    for (final key in keyList) {
      await _removeRaw(key);
    }

    if (keyList.contains(_settingsKey)) {
      _loadSettings();
    } else if (keyList.isNotEmpty) {
      notifyListeners();
    }
  }

  Future<void> storageClear() async {
    final keys = _allKeys().toList(growable: false);
    for (final key in keys) {
      await _removeRaw(key);
    }
    _loadSettings();
  }

  Future<int> storageGetBytesInUse(dynamic keys) async {
    final requested = _requestedKeys(keys);
    final keyList = requested ?? (_allKeys().toList()..sort());

    var total = 0;
    for (final key in keyList) {
      final raw = _rawGet(key);
      if (raw == null) continue;

      final stored = raw is String ? raw : jsonEncode(raw);
      total += utf8.encode(key).length;
      total += utf8.encode(stored).length;
    }
    return total;
  }

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
    return jsonEncode(getAllStorageAsJson());
  }

  Future<void> importFullBackup(Map<String, dynamic> backup) async {
    final before = _getRawSnapshot();

    try {
      for (final entry in backup.entries) {
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
  }
}
