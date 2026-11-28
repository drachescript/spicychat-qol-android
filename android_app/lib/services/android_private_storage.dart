import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

// DS_ANDROID_033_PRIVATE_ENGINE_V1: same transactional QoL logic, separate
// local WebView origin. Never forward arbitrary runtime messages to it.
class AndroidPrivateStorage {
  static const supportedVersion = '0.3.3';
  static const channel = MethodChannel('uk.drache.spicychatqol/app_info');
  static final instance = AndroidPrivateStorage._();
  AndroidPrivateStorage._();

  static const _uuid = r'[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}';
  static final _chatPath = RegExp('^/(?:[a-z]{2}/)?chat/($_uuid)/($_uuid)/?\$', caseSensitive: false);
  static bool trusted(Uri uri) => uri.scheme == 'https' &&
      const {'spicychat.ai', 'www.spicychat.ai'}.contains(uri.host) &&
      uri.userInfo.isEmpty && uri.port == 443;

  static bool matchesChat(Uri uri, Map<dynamic, dynamic> message) {
    if (!trusted(uri)) return false;
    final match = _chatPath.firstMatch(uri.path);
    return match != null && match.group(1)!.toLowerCase() == message['characterId'] &&
        match.group(2)!.toLowerCase() == message['conversationId'];
  }

  static Future<String> request(Map<dynamic, dynamic> message, {required String url, required String version, bool settings = false}) async {
    if (version != supportedVersion) {
      return jsonEncode({'ok': false, 'error': 'Private storage contract requires reviewed QoL $supportedVersion'});
    }
    final type = message['type'];
    if (settings) {
      if (type != 'DS_CHAT_EXPORT_CHECKPOINT' || !const {'settings-overview', 'settings-clear'}.contains(message['action'])) {
        return jsonEncode({'ok': false, 'error': 'Invalid Settings operation'});
      }
    } else {
      final uri = Uri.tryParse(url);
      if (uri == null || !trusted(uri) || (type == 'DS_CHAT_EXPORT_CHECKPOINT' && !matchesChat(uri, message)) ||
          !const {'DS_CHAT_EXPORT_CHECKPOINT', 'DS_GENERATION_QUOTA_RESEARCH'}.contains(type)) {
        return jsonEncode({'ok': false, 'error': 'Invalid private storage scope'});
      }
    }
    try {
      final payload = Map<String, dynamic>.from(message);
      // Android has no Inspector extension connection. Never request a trace
      // containing desktop-only research state as a side effect of a write.
      payload.remove('quotaDiagnostic');
      return await channel.invokeMethod<String>('qolPrivateStorageRequest', {
        'message': jsonEncode(payload), 'url': url, 'settings': settings,
      }) ?? jsonEncode({'ok': false, 'error': 'Private storage unavailable'});
    } catch (_) {
      return jsonEncode({'ok': false, 'error': 'Private storage reply unconfirmed; reopen to verify'});
    }
  }

  static const _maxBytes = 256 * 1024 * 1024;
  static const _maxChunk = 64 * 1024;
  _StreamStage? _stage;
  Timer? _expiry;
  Future<void> _lane = Future<void>.value();
  int _pending = 0;

  Future<Map<String, dynamic>> stream(Map<dynamic, dynamic> message, String scope, bool Function() current) {
    if (_pending >= 4) return Future.value({'ok': false, 'error': 'Native export stream busy'});
    _pending++;
    final result = Completer<Map<String, dynamic>>();
    _lane = _lane.then((_) async {
      try {
        if (!current()) throw StateError('Document changed');
        result.complete(await _stream(message, scope, current));
      } catch (_) {
        // A failed/stale request must not remove a different document's stage.
        if (_stage?.scope == scope && _stage?.id == message['id']) await _discard();
        result.complete({'ok': false, 'error': 'Native stream interrupted; saved capture retained'});
      } finally {
        _pending--;
      }
    });
    return result.future;
  }

  void _touch(_StreamStage stage) {
    _expiry?.cancel();
    _expiry = Timer(const Duration(minutes: 2), () {
      _lane = _lane.then((_) async { if (identical(_stage, stage)) await _discard(); });
    });
  }

  Future<void> _discard() async {
    final stage = _stage;
    _stage = null;
    _expiry?.cancel();
    _expiry = null;
    if (stage == null) return;
    try { await stage.output.close(); } catch (_) {}
    try { await stage.file.delete(); } catch (_) {}
  }

  Future<Map<String, dynamic>> _stream(Map<dynamic, dynamic> message, String scope, bool Function() current) async {
    final action = message['action'];
    if (action == 'open') {
      if (_stage != null && _stage!.scope != scope) await _discard();
      if (_stage != null) return {'ok': false, 'error': 'Another export stream is active'};
      final random = Random.secure();
      final id = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      final cache = await getTemporaryDirectory();
      // Remove only expired interrupted stream stages; never touch downloads.
      try {
        final cutoff = DateTime.now().subtract(const Duration(days: 2));
        await for (final entity in cache.list(followLinks: false)) {
          if (entity is File && RegExp(r'^qol-export-stream-[0-9a-f]{32}\.pending$').hasMatch(entity.uri.pathSegments.last)) {
            if ((await entity.lastModified()).isBefore(cutoff)) {
              try { await entity.delete(); } catch (_) {}
            }
          }
        }
      } catch (_) {}
      final file = File('${cache.path}/qol-export-stream-$id.pending');
      await file.create(exclusive: true);
      try {
        final output = await file.open(mode: FileMode.writeOnly);
        _stage = _StreamStage(id, scope, file, output);
      } catch (_) {
        try { await file.delete(); } catch (_) {}
        rethrow;
      }
      _touch(_stage!);
      return {'ok': true, 'id': id};
    }
    final stage = _stage;
    if (stage == null || stage.scope != scope || message['id'] != stage.id) {
      return {'ok': false, 'error': 'Export stream no longer available'};
    }
    if (action == 'abort') {
      await _discard();
      return {'ok': true};
    }
    if (action == 'write') {
      final encoded = message['base64'];
      if (message['offset'] != stage.bytes || encoded is! String || encoded.isEmpty || encoded.length > 90000) {
        throw const FormatException('Invalid stream chunk');
      }
      final bytes = base64Decode(encoded);
      if (bytes.isEmpty || bytes.length > _maxChunk || stage.bytes + bytes.length > _maxBytes) {
        throw const FormatException('Stream size exceeded');
      }
      await stage.output.writeFrom(bytes);
      stage.hash.add(bytes);
      stage.bytes += bytes.length;
      _touch(stage);
      return {'ok': true, 'bytes': stage.bytes};
    }
    if (action != 'close' || stage.bytes == 0 || message['offset'] != stage.bytes) {
      throw const FormatException('Invalid stream finalization');
    }
    await stage.output.flush();
    await stage.output.close();
    stage.hash.close();
    final digest = stage.digest.value;
    if (digest == null || !current()) throw StateError('Stream changed before save');
    _expiry?.cancel();
    _expiry = null;
    _stage = null; // Native picker now owns the file and Activity recovery.
    try {
      final saved = await channel.invokeMapMethod<String, dynamic>('saveStagedChatExport', {
        'stageName': stage.file.uri.pathSegments.last,
        'filename': message['filename'], 'mimeType': message['mimeType'],
        'bytes': stage.bytes, 'sha256': digest.toString(),
      });
      if (saved?['ok'] == true && saved?['verified'] == true && saved?['bytes'] == stage.bytes) {
        return Map<String, dynamic>.from(saved!);
      }
      return {'ok': false, 'error': saved?['error'] ?? (saved?['canceled'] == true ? 'Export canceled' : 'Native file not verified')};
    } catch (_) {
      // Do not delete a staged file whose picker may have survived the bridge.
      return {'ok': false, 'error': 'Save confirmation unavailable; capture retained'};
    }
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) { value = data; }
  @override
  void close() {}
}

class _StreamStage {
  final String id;
  final String scope;
  final File file;
  final RandomAccessFile output;
  int bytes = 0;
  final digest = _DigestSink();
  late final Sink<List<int>> hash = sha256.startChunkedConversion(digest);
  _StreamStage(this.id, this.scope, this.file, this.output);
}
