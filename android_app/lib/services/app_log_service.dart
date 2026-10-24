import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Small persistent ring log for Android/WebView diagnostics.
///
/// The app intentionally does not send these logs anywhere. They stay on the
/// device until the user copies/exports/clears them from the quick menu.
class AppLogService {
  AppLogService._();

  static final AppLogService instance = AppLogService._();

  static const int _maxBytes = 1024 * 1024;
  static const int _maxBufferedEntries = 200;
  // DS_ANDROID_LOG_BATCH_V060: routine info messages are appended together.
  // WARN/ERROR, renderer, recovery and lifecycle records still flush now.
  static const int _maxBatchEntries = 20;
  static const Duration _batchDelay = Duration(milliseconds: 250);

  final List<String> _batch = <String>[];
  Timer? _batchTimer;

  File? _file;
  bool _initializing = false;
  bool _ready = false;
  final List<String> _pending = <String>[];
  Future<void> _writeChain = Future<void>.value();

  String _stamp() => DateTime.now().toIso8601String();

  String _line(String level, String area, String message) {
    final clean = message.replaceAll('\r', ' ').replaceAll('\n', r'\n');
    return '${_stamp()} [$level] [$area] $clean';
  }

  Future<void> init() async {
    if (_ready || _initializing) return;
    _initializing = true;

    try {
      final base = await getApplicationSupportDirectory();
      final logsDir = Directory('${base.path}${Platform.pathSeparator}logs');
      await logsDir.create(recursive: true);

      _file = File('${logsDir.path}${Platform.pathSeparator}spicychat-qol.log');
      await _rotateIfNeeded();
      _ready = true;

      final queued = List<String>.from(_pending);
      _pending.clear();
      for (final entry in queued) {
        await _append(entry);
      }
      await _append(_line('INFO', 'AppLog', 'Persistent diagnostics log ready'), urgent: true);
    } catch (e, stackTrace) {
      debugPrint('[AppLog] init failed: $e');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      _initializing = false;
    }
  }

  Future<void> _rotateIfNeeded() async {
    final file = _file;
    if (file == null || !await file.exists()) return;

    final length = await file.length();
    if (length <= _maxBytes) return;

    final rotated = File('${file.path}.1');
    if (await rotated.exists()) {
      await rotated.delete();
    }
    await file.rename(rotated.path);
    _file = File(file.path);
  }

  Future<void> _flushBatch({bool durable = false}) async {
    _batchTimer?.cancel();
    _batchTimer = null;
    if (_batch.isEmpty) {
      await _writeChain;
      return;
    }
    final entries = List<String>.from(_batch);
    _batch.clear();
    _writeChain = _writeChain.then((_) async {
      try {
        await _rotateIfNeeded();
        await _file!.writeAsString(
          '${entries.join('\n')}\n',
          mode: FileMode.append,
          flush: durable,
        );
      } catch (e) {
        debugPrint('[AppLog] write failed: $e');
      }
    });
    await _writeChain;
  }

  Future<void> _append(String entry, {bool urgent = false}) async {
    final file = _file;
    if (!_ready || file == null) {
      _pending.add(entry);
      if (_pending.length > _maxBufferedEntries) {
        _pending.removeRange(0, _pending.length - _maxBufferedEntries);
      }
      return;
    }

    _batch.add(entry);
    if (urgent || _batch.length >= _maxBatchEntries) {
      await _flushBatch(durable: urgent);
    } else {
      _batchTimer ??= Timer(
        _batchDelay,
        () => unawaited(_flushBatch()),
      );
    }
  }

  // Can be called before exporting logs or when entering the background.
  Future<void> flush() => _flushBatch(durable: true);

  Future<void> log(
    String area,
    String message, {
    String level = 'INFO',
    Object? error,
    StackTrace? stackTrace,
  }) async {
    final details = StringBuffer(message);
    if (error != null) details.write(' | error=$error');
    if (stackTrace != null) details.write(' | stack=$stackTrace');

    final entry = _line(level, area, details.toString());
    debugPrint(entry);

    if (!_ready && !_initializing) {
      unawaited(init());
    }
    await _append(
      entry,
      urgent: level != 'INFO' ||
          area == 'Renderer' ||
          area == 'Recovery' ||
          area == 'Lifecycle',
    );
  }

  Future<String> readAll() async {
    await init();
    await flush();

    final parts = <String>[];
    final file = _file;
    if (file == null) return '';

    final rotated = File('${file.path}.1');
    if (await rotated.exists()) {
      parts.add(await rotated.readAsString());
    }
    if (await file.exists()) {
      parts.add(await file.readAsString());
    }
    return parts.join();
  }

  Future<void> clear() async {
    await init();
    await flush();

    final file = _file;
    if (file == null) return;
    final rotated = File('${file.path}.1');

    if (await file.exists()) await file.delete();
    if (await rotated.exists()) await rotated.delete();
    _file = File(file.path);
    await _append(_line('INFO', 'AppLog', 'Diagnostics log cleared'));
  }

  Future<String?> filePath() async {
    await init();
    await flush();
    return _file?.path;
  }
}
