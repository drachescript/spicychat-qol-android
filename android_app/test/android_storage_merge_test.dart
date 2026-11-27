import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spicychat_qol_app/services/settings_service.dart';

void main() {
  test('record merge preserves unrelated rows and envelope fields', () {
    final raw = jsonEncode({'version': 3, 'meta': {'a': {'name': 'old'}, 'b': {'name': 'keep'}}});
    final result = mergeNativeStorageRecords({'raw': raw, 'entries': {'a': {'name': 'new'}, 'c': {'name': 'third'}}});
    expect(jsonDecode(result!), {'version': 3, 'meta': {'a': {'name': 'new'}, 'b': {'name': 'keep'}, 'c': {'name': 'third'}}});
    expect(mergeNativeStorageRecords({'raw': result, 'entries': {'a': {'name': 'new'}}}), isNull);
  });
  test('legacy records retained and malformed inputs refused', () {
    expect(jsonDecode(mergeNativeStorageRecords({'raw': '{"a":{"name":"keep"}}', 'entries': {'b': {'name': 'new'}}})!), {'meta': {'a': {'name': 'keep'}, 'b': {'name': 'new'}}});
    expect(() => mergeNativeStorageRecords({'raw': '{"meta":42}', 'entries': {'a': {}}}), throwsFormatException);
    expect(() => mergeNativeStorageRecords({'raw': null, 'entries': {'a': 42}}), throwsFormatException);
  });
  test('explicit GET preserves stored metadata and represents absent stores', () {
    final value = jsonDecode(readNativeLargeValues({
      'botArchive': '{"version":3,"meta":{"a":{"name":"keep"}}}',
      'botAvailability': null,
    }));
    expect(value['data']['botArchive'], {'version': 3, 'meta': {'a': {'name': 'keep'}}});
    expect(value['data']['botAvailability'], {'meta': {}});
    expect(() => readNativeLargeValues({'botArchive': '{"meta":42}'}), throwsFormatException);
  });
  test('explicit replacement rejects malformed stores before writing', () {
    expect(jsonDecode(encodeNativeLargeReplacements({'botArchive': {'a': {'name': 'keep'}}})['botArchive']!),
        {'meta': {'a': {'name': 'keep'}}});
    expect(() => encodeNativeLargeReplacements({'botArchive': null}), throwsFormatException);
    expect(() => encodeNativeLargeReplacements({'botArchive': {'meta': {'a': 2}}}), throwsFormatException);
  });
  test('record removal is scoped, idempotent and preserves metadata', () {
    final result = removeNativeLargeRecords({'raw': '{"version":3,"meta":{"a":{},"b":{}}}', 'ids': ['a', 'a', 'missing']});
    expect(result.removed, 1);
    expect(result.count, 1);
    expect(jsonDecode(result.encoded!), {'version': 3, 'meta': {'b': {}}});
    expect(removeNativeLargeRecords({'raw': result.encoded, 'ids': ['a']}).encoded, isNull);
  });
  test('UTF-8 size matches Dart encoder, including surrogate pairs', () {
    for (final value in ['ASCII', 'König', '日本語', '🐉', String.fromCharCode(0xd800)]) {
      expect(nativeUtf8Length(value), utf8.encode(value).length);
    }
  });
  test('atomic envelope replacement retains complete committed data', () async {
    final dir = await Directory.systemTemp.createTemp('qol-native-store-');
    try {
      final file = File('${dir.path}/archive.json');
      file.writeAsStringSync('previous');
      expect(writeNativeLargeEnvelope({'path': file.path, 'key': 'botArchive', 'value': '{"meta":{}}'}), isTrue);
      expect(jsonDecode(file.readAsStringSync()), {'key': 'botArchive', 'value': '{"meta":{}}'});
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
