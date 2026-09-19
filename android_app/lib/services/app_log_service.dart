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
      await _append(_line('INFO', 'AppLog', 'Persistent diagnostics log ready'));
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

  Future<void> _append(String entry) async {
    final file = _file;
    if (!_ready || file == null) {
      _pending.add(entry);
      if (_pending.length > _maxBufferedEntries) {
        _pending.removeRange(0, _pending.length - _maxBufferedEntries);
      }
      return;
    }

    _writeChain = _writeChain.then((_) async {
      try {
        await _rotateIfNeeded();
        await _file!.writeAsString('$entry\n', mode: FileMode.append, flush: true);
      } catch (e) {
        debugPrint('[AppLog] write failed: $e');
      }
    });
    await _writeChain;
  }

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
    await _append(entry);
  }

  Future<String> readAll() async {
    await init();
    await _writeChain;

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
    await _writeChain;

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
    return _file?.path;
  }
}
