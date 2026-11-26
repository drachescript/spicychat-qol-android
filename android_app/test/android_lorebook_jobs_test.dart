// DS_ANDROID_031_LOREBOOK_JOBS_V1: exercise the actual native checkpoint service.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:spicychat_qol_app/services/android_lorebook_jobs.dart';

const book = '11111111-1111-4111-8111-111111111111';
const run1 = '22222222-2222-4222-8222-222222222222';
const run2 = '33333333-3333-4333-8333-333333333333';
const attempt = '44444444-4444-4444-8444-444444444444';
const entry = '55555555-5555-4555-8555-555555555555';
const accountKey = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final editor = Uri.parse('https://spicychat.ai/lorebook/edit/$book/entries');
final listing = Uri.parse('https://spicychat.ai/my-creations/lorebooks');

void main() {
  late Directory root;
  late int now;
  late AndroidLorebookJobs service;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ds-lorebook-test-');
    now = 1000000;
    service = AndroidLorebookJobs(root:root,clock:()=>now);
  });
  tearDown(() async { await root.delete(recursive:true); });

  Future<Map<String,dynamic>> call(String action, {
    String doc='document-one', String account='account-a', String run=run1,
    Uri? url, Map<String,dynamic> data=const {}, bool current=true,
  }) => service.handle({'bookId':book,'action':action,'accountId':account,'runId':run,...data},
      url??editor,doc,stillCurrent:()=>current);

  Future<String> start() async {
    final r=await call('start',data:{'policy':'skip','payload':{'entries':[
      {'name':'Entry','content':'Test content','keywords':['entry']}
    ]}});
    expect(r['ok'],true,reason:r.toString());
    return (r['job'] as Map)['jobId'] as String;
  }
  Future<Map<String,dynamic>> begin(String job) => call('begin',data:{
    'jobId':job,'index':0,'attemptId':attempt,'kind':'create','result':'created','digest':'digest'});

  test('pending write survives process restart; no blind resend; receipt required',() async {
    final job=await start();
    expect((await call('baseline',data:{'jobId':job,'count':0,'ids':[]}))['ok'],true);
    expect((await begin(job))['ok'],true);
    service=AndroidLorebookJobs(root:root,clock:()=>now);
    final read=await call('get',doc:'document-two');
    expect(read['ok'],true);
    expect((read['job'] as Map)['phase'],'interrupted');
    expect((read['job'] as Map)['pending'],isNotNull);
    expect((await call('cancel-saved',doc:'document-two',data:{'jobId':job}))['ok'],false);
    final resume=await call('resume',doc:'document-two',run:run2,data:{'jobId':job});
    expect(resume['ok'],true);
    expect((resume['job'] as Map)['nextIndex'],0);
    expect((resume['payload'] as Map)['entries'],hasLength(1));
    expect((await call('begin',doc:'document-two',run:run2,data:{'jobId':job,'index':0,'attemptId':attempt,'kind':'create','result':'created'}))['ok'],false);
    final commitData={'jobId':job,'index':0,'attemptId':attempt,'result':'created','entryId':entry};
    expect((await call('commit',doc:'document-two',run:run2,data:commitData))['ok'],false);
    expect((await call('receipt',doc:'document-two',run:run2,data:{'jobId':job,'attemptId':attempt,'status':201,'entryId':entry}))['ok'],true);
    final commit=await call('commit',doc:'document-two',run:run2,data:commitData);
    expect(commit['ok'],true);
    expect((commit['job'] as Map)['nextIndex'],1);
    expect((await call('commit',doc:'document-two',run:run2,data:commitData))['ok'],false);
    expect((await call('finish',doc:'document-two',run:run2,data:{'jobId':job,'verifiedCount':1,'verificationMode':'ids'}))['ok'],true);
  });

  test('route, stale document, and account checks fail closed',() async {
    expect((await call('peek',url:Uri.parse('https://example.com/lorebook/edit/$book/entries')))['ok'],false);
    expect((await call('peek',current:false))['ok'],false);
    await start();
    expect((await call('get',account:'other-account'))['ok'],false);
    expect((await call('get',url:listing))['ok'],false);
  });

  test('backup lease and unresolved import exclude each other',() async {
    final lease=await call('backup-acquire',url:listing,run:run2);
    expect(lease['acquired'],true);
    expect((await call('start',data:{'policy':'skip','payload':{'entries':[{'name':'Entry','content':'Test','keywords':[]}]}}))['ok'],false);
    expect((await call('backup-release',url:listing,run:run2))['released'],true);
    final job=await start();
    expect((await call('backup-acquire',url:listing,run:run2))['reason'],'import-active');
    expect((await begin(job))['ok'],true);
    now+=180001;
    expect((await call('backup-acquire',url:listing,run:run2))['reason'],'import-uncertain');
  });

  test('capture cache retains complete snapshot across interrupted replacement',() async {
    final data={'accountKey':accountKey,'total':1};
    final row={'id':entry,'name':'Entry','content':'Original','keywords':['one']};
    expect((await call('capture-start',data:data))['acquired'],true);
    expect((await call('capture-page',data:{...data,'offset':0,'entries':[row]}))['saved'],1);
    expect((await call('capture-finish',data:{...data,'meta':{'id':book,'name':'Book','entryCount':1}}))['verified'],1);
    expect((await call('capture-start',run:run2,data:data))['acquired'],true);
    expect((await call('capture-page',run:run2,data:{...data,'offset':0,'entries':[{...row,'content':'New'}]}))['changed'],1);
    service=AndroidLorebookJobs(root:root,clock:()=>now);
    final old=await call('capture-read',data:data);
    expect(old['ok'],true);
    expect((((old['snapshot'] as Map)['entries'] as List).single as Map)['content'],'Original');
    expect((await call('capture-clear',data:data))['ok'],false);
    now+=180001;
    expect((await call('capture-clear',data:data))['cleared'],true);
    expect((await call('capture-read',data:data))['snapshot'],isNull);
  });
}
