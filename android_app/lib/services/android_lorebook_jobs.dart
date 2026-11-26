// DS_ANDROID_031_LOREBOOK_JOBS_V1
// Native, app-private checkpoints. No network or native entry-writing API here.
// The shared editor owns authentication, native validation and server receipts.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

typedef _Json = Map<String, dynamic>;

class AndroidLorebookJobs {
  AndroidLorebookJobs({Directory? root, int Function()? clock})
    : _root = root, _clock = clock ?? _now;

  static final instance = AndroidLorebookJobs();
  static final _uuid = RegExp(r'^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$');
  static final _digest = RegExp(r'^[a-f0-9]{64}$');
  static final _editor = RegExp(r'^/lorebook/(?:edit/([0-9a-f-]{36})|([0-9a-f-]{36})/edit)(?:/(entries|details))?$');
  static const _leaseMs = 180000;
  static const _maxSourceBytes = 48 * 1024 * 1024;
  static const _maxCaptureBytes = 64 * 1024 * 1024;
  static final _random = Random.secure();
  final int Function() _clock;
  Directory? _root;
  Future<void> _tail = Future<void>.value();

  static int _now() => DateTime.now().millisecondsSinceEpoch;
  static String _newId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final s = bytes.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${s.substring(0,8)}-${s.substring(8,12)}-${s.substring(12,16)}-${s.substring(16,20)}-${s.substring(20)}';
  }

  static bool _isId(dynamic v) => v is String && _uuid.hasMatch(v);
  static bool _intIn(dynamic v, int min, int max) => v is int && v >= min && v <= max;
  static bool _stringIn(dynamic v, int max) => v is String && v.trim().isNotEmpty && v.length <= max;
  static _Json? _map(dynamic v) => v is Map<String, dynamic> ? v : null;
  static Never _fail(String message) => throw _JobError(message);
  static bool _terminal(_Json j) => const ['completed','cancelled'].contains(j['phase']);
  static bool _live(_Json? owner, int now) => owner?['until'] is int && (owner!['until'] as int) > now;

  Future<Directory> _directory(String bookId) async {
    if (_root == null) {
      const channel = MethodChannel('uk.drache.spicychatqol/app_info');
      final path = await channel.invokeMethod<String>('getLorebookJobDirectory');
      if (path == null || path.isEmpty) {
        _fail('Private Lorebook storage is unavailable.');
      }
      _root = Directory(path);
    }
    final dir = Directory('${_root!.path}/$bookId');
    await dir.create(recursive: true);
    return dir;
  }

  Future<_Json?> _read(File file, {int limit = _maxSourceBytes}) async {
    if (!await file.exists()) return null;
    if (await file.length() > limit) { _fail('Saved Lorebook checkpoint exceeds the native size limit. Nothing changed.'); }
    final raw = jsonDecode(await file.readAsString());
    final result = _map(raw);
    if (result == null) { _fail('Saved Lorebook checkpoint is unreadable. Nothing changed.'); }
    return result;
  }

  Future<void> _write(File file, _Json data, {int limit = _maxSourceBytes}) async {
    final bytes = utf8.encode(jsonEncode(data));
    if (bytes.length > limit) { _fail('Lorebook checkpoint exceeds the native size limit. Nothing changed.'); }
    final temp = File('${file.path}.${_newId()}.tmp');
    try {
      await temp.writeAsBytes(bytes, flush: true);
      // Same-directory POSIX rename replaces the prior committed file without
      // deleting it first. Source is committed before the job points to it.
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<Map<String, dynamic>> handle(Map<String, dynamic> message, Uri url, String documentId,
      {required bool Function() stillCurrent}) {
    final result = Completer<_Json>();
    _tail = _tail.then((_) async {
      try {
        if (!stillCurrent()) { _fail('WebView document changed. No checkpoint action performed.'); }
        result.complete(await _handle(message, url, documentId));
      } on _JobError catch (e) {
        result.complete({'ok': false, 'error': e.message});
      } catch (_) {
        // No source, account ID, path or filesystem exception in diagnostics.
        result.complete({'ok': false, 'error': 'Native Lorebook checkpoint storage failed. Reopen the job to verify its state.'});
      }
    });
    return result.future;
  }

  Future<_Json> _handle(_Json m, Uri url, String document) async {
    final action = m['action'];
    final id = m['bookId'];
    if (url.scheme != 'https' || !const ['spicychat.ai','www.spicychat.ai'].contains(url.host) ||
        !_isId(id) || !_stringIn(document, 160) || action is! String) {
      _fail('Invalid Lorebook checkpoint context.');
    }
    final bookId = id as String;
    final path = url.path.replaceFirst(RegExp(r'^/[a-z]{2}(?=/)'), '').replaceFirst(RegExp(r'/+$'), '');
    final match = _editor.firstMatch(path);
    final matchesBook = (match?.group(1) ?? match?.group(2))?.toLowerCase() == bookId;
    final listing = path == '/my-creations/lorebooks';
    if (action.startsWith('capture-')) {
      if (!listing && !matchesBook) { _fail('Invalid Lorebook capture context.'); }
      return _capture(m, await _directory(bookId), document);
    }
    if (const ['backup-acquire','backup-renew','backup-release'].contains(action)) {
      if (!listing || !_isId(m['runId'])) { _fail('Invalid bulk Lorebook backup context.'); }
      return _backup(m, await _directory(bookId), document);
    }
    if (!matchesBook || match?.group(3) != 'entries' ||
        (action != 'peek' && !_stringIn(m['accountId'], 160))) {
      _fail('Open the exact owned Lorebook Entries page.');
    }
    return _import(m, await _directory(bookId), document);
  }

  Future<_Json> _state(Directory dir) async {
    final file = File('${dir.path}/state.json');
    final state = await _read(file);
    if (state == null) return {'schema': 1};
    if (state['schema'] != 1 || (state['job'] != null && _map(state['job']) == null) ||
        (state['backup'] != null && _map(state['backup']) == null)) {
      _fail('Saved Lorebook job has an unsupported format. Nothing changed.');
    }
    return state;
  }

  Future<void> _saveState(Directory dir, _Json state) => _write(File('${dir.path}/state.json'), state);

  _Json _owner(dynamic runId, String document, int now) =>
      {'runId':runId,'tabId':1,'documentId':document,'until':now + _leaseMs};

  Future<_Json> _import(_Json m, Directory dir, String document) async {
    final action = m['action'];
    final now = _clock();
    final state = await _state(dir);
    var job = _map(state['job']);
    if (action == 'peek') return {'ok':true,'exists':job != null};
    if (job != null && job['accountId'] != m['accountId']) { _fail('Saved import belongs to another account. No entries changed.'); }
    final oldOwner = _map(job?['owner']);
    final live = _live(oldOwner, now);
    final owns = live && oldOwner?['runId'] == m['runId'] && oldOwner?['documentId'] == document;
    final sameReload = live && oldOwner?['documentId'] != document;
    if (action == 'get') {
      if (job != null && oldOwner != null && (!live || sameReload)) {
        job['owner'] = null; job['phase'] = 'interrupted';
        job['interruption'] = 'Editor or extension stopped responding';
        job['checkpointAt'] = now;
        await _saveState(dir, state);
      }
      return {'ok':true,'job':job,'locked':live && !sameReload && !owns};
    }
    if (const ['start','resume'].contains(action) && _live(_map(state['backup']), now)) {
      _fail('A live backup is collecting this Lorebook. Wait for it to finish.');
    }
    if (action == 'start') {
      if (job != null && (!_terminal(job) || job['pending'] != null)) { _fail('A saved import already exists. Resume or cancel it instead.'); }
      final payload = _map(m['payload']);
      final entries = payload?['entries'];
      if (!_isId(m['runId']) || entries is! List || entries.isEmpty || entries.length > 5000 ||
          !const ['skip','merge','replace','add'].contains(m['policy'])) { _fail('Invalid import source or policy.'); }
      for (final raw in entries) {
        final entry = _map(raw);
        final keywords = entry?['keywords'];
        if (entry == null || !_stringIn(entry['name'], 50) || !_stringIn(entry['content'], 2000) ||
            keywords is! List || keywords.length > 12 || keywords.any((k) => !_stringIn(k, 80))) {
          _fail('An entry exceeds supported name, content or keyword limits. Nothing imported.');
        }
      }
      final oldId = job?['jobId'];
      final newId = _newId();
      job = {'jobId':newId,'bookId':m['bookId'],'accountId':m['accountId'],'policy':m['policy'],
        'total':entries.length,'nextIndex':0,'results':<dynamic>[],'pending':null,'phase':'preparing',
        'createdAt':now,'lastSuccess':0,'retries':0,'resumes':0,'owner':_owner(m['runId'],document,now),'checkpointAt':now,
        'sourceHash':sha256.convert(utf8.encode(jsonEncode(payload))).toString()};
      await _write(File('${dir.path}/source-$newId.json'), payload!);
      state['job'] = job;
      await _saveState(dir, state);
      if (_isId(oldId)) {
        try { await File('${dir.path}/source-$oldId.json').delete(); } catch (_) {}
      }
      return {'ok':true,'job':job};
    }
    if (job == null || !_isId(job['jobId']) || m['jobId'] != job['jobId']) { _fail('Saved import changed. Reopen the job.'); }
    final j = job;
    if (!_intIn(j['total'],1,5000) || !_intIn(j['nextIndex'],0,j['total'] as int) ||
        j['results'] is! List || (j['results'] as List).length != j['nextIndex']) { _fail('Saved import cursor is invalid. Nothing changed.'); }
    final pending = _map(j['pending']);
    if (j['pending'] != null && pending == null) { _fail('Saved pending write is invalid. Nothing changed.'); }
    Future<_Json> save({bool checkpoint = true}) async {
      if (checkpoint) j['checkpointAt'] = now;
      state['job'] = j;
      await _saveState(dir, state);
      return {'ok':true,'job':j};
    }
    if (action == 'resume') {
      if (_terminal(j) || (live && !sameReload && !owns) || !_isId(m['runId'])) { _fail('Import is running elsewhere or already finished.'); }
      final source = await _read(File('${dir.path}/source-${j['jobId']}.json'));
      if (source == null || source['entries'] is! List || (source['entries'] as List).length != j['total'] ||
          sha256.convert(utf8.encode(jsonEncode(source))).toString() != j['sourceHash']) {
        _fail('Saved import source is missing, incomplete or changed.');
      }
      j['owner'] = _owner(m['runId'],document,now); j['resumes'] = (j['resumes'] as int) + 1;
      j['phase'] = pending != null ? 'checking-uncertain-save' : 'preparing';
      return {...(await save()),'payload':source};
    }
    if (action == 'cancel-saved') {
      if (live && !sameReload) { _fail('Pause the running import first.'); }
      if (pending != null) { _fail('An uncertain save must be reconciled before cancelling this job.'); }
      j['phase']='cancelled'; j['owner']=null; return save();
    }
    if (!owns || !_isId(m['runId'])) { _fail('Import ownership expired or changed; reopen the job before continuing.'); }
    j['owner'] = _owner(m['runId'],document,now);
    final cursor = j['nextIndex'] as int;
    final total = j['total'] as int;
    final results = j['results'] as List;
    final receipt = _map(pending?['receipt']);
    switch (action) {
      case 'heartbeat':
        j['phase'] = pending != null ? 'waiting-for-save' : _short(m['phase'],'running',40);
        return save(checkpoint:false);
      case 'baseline':
        if (!_intIn(m['count'],0,5000)) { _fail('Unsupported Lorebook count.'); }
        j['initialCount'] ??= m['count'];
        final ids = m['ids'];
        if (ids is List && ids.length == m['count'] && ids.every(_isId) && ids.toSet().length == ids.length && pending == null) j['baselineIds'] = ids;
        j['phase']='running'; return save();
      case 'begin':
        final kind = m['kind'] == 'update' ? 'update' : 'create';
        if (pending != null || m['index'] != cursor || cursor >= total || !_isId(m['attemptId']) ||
            !const ['created','merged','replaced'].contains(m['result']) ||
            ((m['result'] == 'created') != (kind == 'create'))) { _fail('A previous write is unresolved or the import cursor changed.'); }
        j['pending']={'index':cursor,'attemptId':m['attemptId'],'at':now,'kind':kind,'result':m['result'],'digest':m['digest']};
        j['phase']='waiting-for-save'; return save();
      case 'not-sent':
        if (pending == null || pending['attemptId'] != m['attemptId'] || receipt != null) { _fail('Cannot clear an attempted write.'); }
        j['pending']=null; j['phase']='running'; return save();
      case 'receipt':
        if (pending == null || pending['attemptId'] != m['attemptId'] || m['status'] is! int || receipt != null) { _fail('Receipt is not for the pending write.'); }
        pending['receipt']={'status':m['status'],'entryId':_isId(m['entryId'])?m['entryId']:null,'at':now}; return save();
      case 'rejected':
        if (pending == null || pending['attemptId'] != m['attemptId'] || !const [400,401,403,404,422].contains(m['status']) || receipt?['status'] != m['status']) { _fail('Write rejection is not definitive.'); }
        j['pending']=null; j['retries']=(j['retries'] as int)+1; j['phase']='paused';
        j['interruption']='Server rejected the entry (HTTP ${m['status']})'; j['owner']=null; return save();
      case 'commit':
        final result = m['result']; final entryId=m['entryId'];
        if (m['index'] != cursor || cursor >= total || !const ['created','skipped','merged','replaced'].contains(result)) { _fail('Invalid import checkpoint.'); }
        if (result == 'skipped') {
          if (pending != null || j['policy'] != 'skip') { _fail('Unexpected skip.'); }
        } else {
          final baseline = j['baselineIds'];
          final duplicate = results.any((r) => r is Map && r['id'] == entryId) || (baseline is List && baseline.contains(entryId));
          if (pending == null || pending['attemptId'] != m['attemptId'] || !_isId(entryId) ||
              ((result == 'created') != (pending['kind'] == 'create')) || (result == 'created' && duplicate) || result != pending['result']) { _fail('Missing or conflicting server entry identity.'); }
          final status = receipt?['status'];
          final observed = status is int && status >= 200 && status < 300 && receipt?['entryId'] == entryId;
          final reconciled = m['reconciled'] == true && baseline is List && pending['kind'] == 'create';
          if (!observed && !reconciled) { _fail('Server receipt or verified reconciliation required.'); }
        }
        results.add({'index':cursor,'action':result,'id':entryId,'digest':pending?['digest'],'at':now,
          if (result=='skipped' && m['verifiedExisting']==true && _isId(m['verifiedExistingId'])) ...{
            'verifiedExisting':true,'verifiedExistingId':m['verifiedExistingId']}});
        j['nextIndex']=cursor+1; if (result!='skipped') j['lastSuccess']=receipt?['at']??now;
        j['pending']=null; j['phase']='running'; return save();
      case 'finish':
        if (pending != null || cursor != total || !_intIn(m['verifiedCount'],0,5000)) { _fail('Cannot mark an incomplete import finished.'); }
        j['verifiedCount']=m['verifiedCount']; j['verificationMode']=m['verificationMode']=='ids'?'ids':'native';
        j['phase']='completed'; j['owner']=null; return save();
      case 'stop':
        j['phase']=m['phase']=='cancelled'&&pending==null?'cancelled':m['phase']=='paused'?'paused':'interrupted';
        j['interruption']=_short(m['reason'],'Import stopped',240); j['owner']=null; return save();
      default: _fail('Unknown import operation.');
    }
  }

  static String _short(dynamic v, String fallback, int max) {
    final s = v is String && v.isNotEmpty ? v : fallback;
    return s.length <= max ? s : s.substring(0,max);
  }

  Future<_Json> _backup(_Json m, Directory dir, String document) async {
    final state=await _state(dir), now=_clock();
    final j=_map(state['job']), old=_map(state['backup']);
    final ours=old?['runId']==m['runId']&&old?['documentId']==document;
    final active=_live(_map(j?['owner']),now);
    final summary=<String,dynamic>{'importJobId':j?['jobId'],'phase':j?['phase'],
      'processed':j?['nextIndex'],'total':j?['total'],
      'verifiedCount': (j?['phase'] == 'completed') ? (j?['verifiedCount']) : null};
    if(m['action']=='backup-release') {
      if(ours){state.remove('backup');await _saveState(dir,state);} return {'ok':true,'released':ours};
    }
    if(m['action']=='backup-renew'&&(!ours||!_live(old,now)||active||j?['pending']!=null)) return {'ok':true,'acquired':false,'reason':'lease-lost'};
    if(active||j?['pending']!=null) return {'ok':true,'acquired':false,'reason':active?'import-active':'import-uncertain',...summary};
    if(m['action']=='backup-acquire'&&m['waitingJobId']!=null&&j!=null&&j['jobId']==m['waitingJobId']&&!_terminal(j)) return {'ok':true,'acquired':false,'reason':'import-paused',...summary};
    if(_live(old,now)&&!ours) return {'ok':true,'acquired':false,'reason':'backup-active',...summary};
    state['backup']=_owner(m['runId'],document,now);await _saveState(dir,state);
    return {'ok':true,'acquired':true,...summary};
  }

  // The capture cache is account-scoped and row content-addressed. The old
  // complete manifest remains authoritative until all new rows are committed.
  Future<_Json> _capture(_Json m, Directory dir, String document) async {
    final account=m['accountKey'], action=m['action'], run=m['runId'];
    if(account is! String||!_digest.hasMatch(account)||
        (!const ['capture-read','capture-clear'].contains(action)&&!_isId(run))) { _fail('Invalid Lorebook capture context.'); }
    final base=Directory('${dir.path}/capture-$account'); await base.create(recursive:true);
    final file=File('${base.path}/capture.json');
    final state=await _read(file)??<String,dynamic>{'schema':1};
    if(state['schema']!=1) { _fail('Unsupported saved capture format.'); }
    final complete=_map(state['complete']), draft=_map(state['draft']);
    final now=_clock(), active=_live(draft,now), owns=draft?['runId']==run&&draft?['documentId']==document;
    List<dynamic> keys(_Json? v) => (v?['keys'] as List?)??const [];
    List<dynamic> ids(_Json? v) => (v?['ids'] as List?)??const [];
    File rowFile(dynamic key) {
      if(key is! String||!RegExp(r'^[0-9a-f-]{36}-[0-9a-f]{64}$').hasMatch(key)) { _fail('Saved capture row identity invalid.'); }
      return File('${base.path}/row-$key.json');
    }
    Future<void> save() => _write(file,state);
    Future<void> prune(Set<dynamic> keep) async {
      try {
        await for(final e in base.list(followLinks:false)) {
          if(e is! File) continue;
          final name=e.uri.pathSegments.last;
          final match=RegExp(r'^row-([0-9a-f-]{36}-[0-9a-f]{64})\.json$').firstMatch(name);
          if(match!=null&&!keep.contains(match.group(1))) await e.delete();
        }
      } catch (_) { /* stale immutable rows do not invalidate a committed manifest */ }
    }
    if(action=='capture-read') {
      if(complete==null) return {'ok':true,'snapshot':null};
      final rows=<dynamic>[];var bytes=0;final rowKeys=keys(complete), rowIds=ids(complete);
      if(rowKeys.length!=rowIds.length||rowKeys.length>5000) { _fail('Saved capture manifest is incomplete.'); }
      for(var i=0;i<rowKeys.length;i++) {
        final f=rowFile(rowKeys[i]); bytes+=await f.length(); if(bytes>_maxCaptureBytes) { _fail('Saved capture exceeds native read limit.'); }
        final row=await _read(f,limit:256*1024);
        if(row==null||row['id']!=rowIds[i] || !rowKeys[i].toString().endsWith(sha256.convert(utf8.encode(jsonEncode(row))).toString())) {
          _fail('Saved capture is missing an entry or its integrity check failed.');
        }
        rows.add(row);
      }
      final at=complete['at'] as int;
      return {'ok':true,'snapshot':{'schema':'spicychat-qol-lorebook-recovery-copy','version':1,'savedAt':at,
        'fetchedAt':DateTime.fromMillisecondsSinceEpoch(at,isUtc:true).toIso8601String(),'source':'saved-verified-capture',
        'completeness':{'details':true,'entries':true,'entryCountVerified':true},'lorebook':complete['meta'],'entries':rows}};
    }
    if(action=='capture-clear') {
      if(active) { _fail('A capture is still active. Finish it before clearing its cache.'); }
      state.remove('complete');state.remove('draft');await save();await prune({});return {'ok':true,'cleared':true};
    }
    if(action=='capture-start') {
      if(active&&!owns) return {'ok':true,'acquired':false};
      if(!_intIn(m['total'],0,5000)) { _fail('Invalid capture total.'); }
      final prior=List<dynamic>.from(keys(draft));
      state['draft']={..._owner(run,document,now),'total':m['total'],'keys':<dynamic>[],'ids':<dynamic>[],
        'prior':prior,'startedAt':now,'bytes':0};
      await save();await prune({...keys(complete),...prior});
      return {'ok':true,'acquired':true,'previouslySaved':prior.length,'previousComplete':keys(complete).length};
    }
    if(draft==null||!owns) { _fail('Lorebook capture ownership changed.'); }
    if(action=='capture-stop') {draft['until']=0;await save();return {'ok':true,'saved':keys(draft).length};}
    if(!active) { _fail('Lorebook capture lease expired.'); }
    if(action=='capture-page') {
      final rows=m['entries'], dKeys=keys(draft), dIds=ids(draft), total=draft['total'];
      if(rows is! List||rows.length>100||m['offset']!=dKeys.length||m['total']!=total||total is! int||dKeys.length+rows.length>total) { _fail('Capture page order or count changed.'); }
      final seen=dIds.toSet(), previous=<dynamic,dynamic>{};
      for(var i=0;i<ids(complete).length;i++){previous[ids(complete)[i]]=keys(complete)[i];}
      final newKeys=<String>[],newIds=<String>[]; var reused=0,added=0,changed=0,bytes=(draft['bytes'] as int?)??0;
      for(final raw in rows) {
        final row=_map(raw); final id=row?['id'];
        if(row==null||!_isId(id)||!seen.add(id)||row['content'] is! String||(row['content'] as String).length>24000||row['name'] is! String||row['keywords'] is! List) { _fail('Invalid capture row.'); }
        final json=jsonEncode(row); if(json.length>64000) { _fail('Capture row too large.'); }
        final encoded=utf8.encode(json); bytes+=encoded.length;if(bytes>_maxCaptureBytes) { _fail('Capture exceeds native storage limit; previous complete capture retained.'); }
        final hash=sha256.convert(encoded).toString(), key='$id-$hash', target=rowFile(key);
        if(await target.exists()) {
          // Verify existing immutable bytes before reusing.
          final stored=await target.readAsBytes();if(sha256.convert(stored).toString()!=hash) _fail('Saved capture row integrity failed.');reused++;
        } else {await _write(target,row,limit:256*1024);}
        if(!previous.containsKey(id)){added++;}else if(previous[id]!=key){changed++;}
        newKeys.add(key);newIds.add(id as String);
      }
      dKeys.addAll(newKeys);dIds.addAll(newIds);draft['bytes']=bytes;draft['until']=now+_leaseMs;await save();
      return {'ok':true,'reused':reused,'added':added,'changed':changed,'saved':dKeys.length};
    }
    if(action=='capture-finish') {
      final meta=_map(m['meta']); final dKeys=keys(draft),dIds=ids(draft);
      if(dKeys.length!=draft['total']||dIds.length!=dKeys.length||meta==null||meta['id']!=m['bookId']||meta['entryCount']!=draft['total']||meta['name'] is! String) { _fail('Capture not complete.'); }
      final removed=ids(complete).toSet().difference(dIds.toSet()).length;
      state['complete']={'keys':dKeys,'ids':dIds,'meta':meta,'at':now};state.remove('draft');await save();await prune(dKeys.toSet());
      return {'ok':true,'verified':dKeys.length,'removed':removed};
    }
    _fail('Unknown Lorebook capture operation.');
  }
}

class _JobError implements Exception {
  const _JobError(this.message);
  final String message;
}
