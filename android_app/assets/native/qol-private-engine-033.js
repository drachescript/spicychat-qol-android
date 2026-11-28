// DS_ANDROID_033_PRIVATE_ENGINE_V1; upstream d6f0045eb8e091b2f00dfe46853553d0fd1dc589
(()=>{
"use strict";
function idbRequest(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error || new Error("IndexedDB request failed."));
  });
}

// Chat export pages live in a separate extension-origin database. The page and
// its cursor are committed in the same transaction; no chat text goes into sync,
// chrome.storage.local, or diagnostic events.
let dsqChatExportDatabase = null;
const dsqChatExportProtectedTabs = new Map();
function dsqChatExportTabProtected(tab) {
  const row = dsqChatExportProtectedTabs.get(Number(tab?.id));
  if (!row) return false;
  if (row.until < Date.now() || !String(tab?.url || '').includes(row.path)) {
    dsqChatExportProtectedTabs.delete(Number(tab?.id)); return false;
  }
  return true;
}
function dsqOpenChatExportDatabase() {
  if (!dsqChatExportDatabase) dsqChatExportDatabase = new Promise((resolve, reject) => {
    const r = indexedDB.open('dsq-chat-export-checkpoints-v1', 1);
    r.onupgradeneeded = () => {
      r.result.createObjectStore('jobs');
      r.result.createObjectStore('pages');
    };
    r.onsuccess = () => {
      const db = r.result;
      db.onversionchange = () => { db.close(); dsqChatExportDatabase = null; };
      resolve(db);
    };
    r.onerror = () => reject(r.error || Error('Could not open export checkpoints'));
    r.onblocked = () => reject(Error('Export checkpoint database is blocked'));
  }).catch(error => { dsqChatExportDatabase = null; throw error; });
  return dsqChatExportDatabase;
}
function dsqChatExportScope(sender, message) {
  const uuid = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
  const url = new URL(sender?.url || sender?.tab?.url || '');
  const parts = url.pathname.split('/').filter(Boolean);
  const index = parts.indexOf('chat');
  const bot = String(parts[index+1] || '').toLowerCase();
  const conv = String(parts[index+2] || '').toLowerCase();
  if (sender?.id !== chrome.runtime.id || sender?.frameId !== 0 ||
      url.protocol !== 'https:' || !['spicychat.ai','www.spicychat.ai'].includes(url.hostname) ||
      index < 0 || parts.length !== index+3 || !uuid.test(bot) || !uuid.test(conv) ||
      bot !== message.characterId || conv !== message.conversationId) throw Error('Open the exact saved conversation to access its export checkpoint.');
  return { key: `${bot}:${conv}`, path: `/chat/${bot}/${conv}`, tabId: Number(sender.tab?.id) };
}
// Settings maintenance is authorized independently of the conversation route.
// The reviewed snapshot is kept in worker memory, never returned with IDs/text.
let dsqChatExportClearReview = null;
function dsqChatExportMaintenance(message, sender) {
  if (sender?.id !== chrome.runtime.id || String(sender?.url || '').split(/[?#]/,1)[0] !== chrome.runtime.getURL('options.html') || (sender.frameId != null && sender.frameId !== 0)) throw Error('Export maintenance is available only from QoL Settings.');
  const active = () => [...dsqChatExportProtectedTabs.values()].some(row => row.until > Date.now());
  return dsqOpenChatExportDatabase().then(db => new Promise((resolve,reject) => {
    const clearing = message.action === 'settings-clear';
    const tx = db.transaction(['jobs','pages'], clearing ? 'readwrite' : 'readonly');
    const jobs = tx.objectStore('jobs'), pages = tx.objectStore('pages');
    let result, failure;
    const abort = error => { failure=error; try{tx.abort();}catch{} };
    tx.oncomplete=()=>resolve({ok:true,...result});
    tx.onabort=tx.onerror=()=>reject(failure||tx.error||Error('Export maintenance transaction failed'));
    const keys=jobs.getAllKeys(), rows=jobs.getAll(), pageCount=pages.count();
    let ready=0;
    const finish=()=>{
      if(++ready!==3)return;
      try{
        const values=rows.result||[], ids=keys.result||[];
        const signature=JSON.stringify(ids.map((key,i)=>[key,values[i]?.jobId,values[i]?.revision]));
        const counts={captures:values.length,pages:pageCount.result,messages:values.reduce((n,row)=>n+Math.max(0,Number(row.rawUniqueCount)||0),0)};
        // A recent unfinished job may have survived a worker restart. Require
        // the user to stop it first, or wait until its short lease expires.
        const running=active()||values.some(row=>row.reason==='fetching'&&Date.now()-Number(row.checkpointAt||0)<300000);
        if(!clearing){
          const token=crypto.randomUUID();dsqChatExportClearReview={token,signature,pages:counts.pages,until:Date.now()+120000};
          result={...counts,token,active:running};return;
        }
        const review=dsqChatExportClearReview;
        if(!review||message.token!==review.token||review.until<Date.now()||review.signature!==signature||review.pages!==counts.pages)throw Error('Saved exports changed or review expired. Check saved exports again.');
        if(running)throw Error('An export may still be active. Pause fetching or finish the download before clearing; retry after the protection window if necessary.');
        // Both stores are cleared atomically. No other database is touched.
        pages.clear();jobs.clear();dsqChatExportClearReview=null;result={cleared:true,...counts};
      }catch(error){abort(error);}
    };
    keys.onsuccess=finish;rows.onsuccess=finish;pageCount.onsuccess=finish;
  }));
}
async function dsqChatExportCheckpoint(message, sender) {
  if (message.action === 'settings-overview' || message.action === 'settings-clear') return dsqChatExportMaintenance(message,sender);
  const scope = dsqChatExportScope(sender, message);
  const action = message.action;
  if (action === 'release') { dsqChatExportProtectedTabs.delete(scope.tabId); return { ok: true }; }
  if (scope.tabId) dsqChatExportProtectedTabs.set(scope.tabId, {path:scope.path,until:Date.now()+300000});
  if(action==='download-status'){
    // Exact, unguessable blob URL from this conversation's origin only. Do not
    // expose browser download lists, paths, filenames or unrelated URLs.
    const url=String(message.blobUrl||'');
    const origin=new URL(sender.url||sender.tab.url).origin;
    if(!url.startsWith(`blob:${origin}/`)||! /^[0-9a-f-]{36}$/i.test(url.slice(`blob:${origin}/`.length)))throw Error('Invalid export download reference');
    if(!chrome.downloads?.search||!chrome.permissions?.contains)return {ok:true,state:'unavailable'};
    const granted=await new Promise(resolve=>chrome.permissions.contains({permissions:['downloads']},allowed=>resolve(!chrome.runtime.lastError&&allowed)));
    if(!granted)return {ok:true,state:'unavailable'};
    return new Promise(resolve=>chrome.downloads.search({url,limit:2},items=>{
      if(chrome.runtime.lastError)return resolve({ok:true,state:'unavailable'});
      const matches=(items||[]).filter(item=>item.url===url||item.finalUrl===url);
      if(matches.length!==1)return resolve({ok:true,state:'unconfirmed'});
      const item=matches[0];
      resolve({ok:true,state:['complete','interrupted','in_progress'].includes(item.state)?item.state:'unconfirmed'});
    }));
  }
  const db = await dsqOpenChatExportDatabase();
  const write = action === 'commit' || action === 'clear' || action==='append';
  return new Promise((resolve, reject) => {
    const tx = db.transaction(['jobs','pages'], write ? 'readwrite' : 'readonly');
    const jobs = tx.objectStore('jobs'), pages = tx.objectStore('pages');
    let result, failure;
    const abort = error => { failure = error; try { tx.abort(); } catch {} };
    tx.oncomplete = () => resolve({ok:true,...result});
    tx.onabort = tx.onerror = () => reject(failure || tx.error || Error('Export checkpoint transaction failed'));
    const req = jobs.get(scope.key);
    req.onsuccess = () => {
      try {
        const old = req.result || null;
        if (action === 'get') { result = { job: old }; return; }
        if (action === 'page') {
          if (!old || old.jobId !== message.jobId || !Number.isInteger(message.page) || message.page < 1 || message.page > old.pages) throw Error('Checkpoint page is no longer available');
          const read = pages.get([scope.key,message.page]);
          read.onsuccess = () => {
            if (!read.result || read.result.jobId !== old.jobId) { abort(Error('Missing saved export page')); return; }
            const {jobId,...page} = read.result;
            result = {page:message.idsOnly ? {...page,messages:undefined,activeRoles:page.activeRoles} : page};
          };
          return;
        }
        if (action === 'clear') {
          if (!old || old.jobId !== message.jobId || old.revision !== message.revision) throw Error('Checkpoint changed; reopen export before clearing');
          pages.delete(IDBKeyRange.bound([scope.key,0],[scope.key,Number.MAX_SAFE_INTEGER]));
          jobs.delete(scope.key); result = {}; return;
        }
        if(action==='append'){
          const next=message.job, batch=message.appendPages;
          if(!old||!next||old.jobId!==next.jobId||next.revision!==old.revision+1||!['api-exhausted','api-chain-start'].includes(old.reason)||!Array.isArray(batch)||!batch.length||batch.length>25||next.pages!==old.pages+batch.length)throw Error('Saved capture changed or invalid append batch');
          const ranges=old.pageSegments||(old.pages?[{first:1,last:old.pages}]:[]);
          if(JSON.stringify(next.pageSegments)!==JSON.stringify([...ranges,{first:old.pages+1,last:next.pages}]))throw Error('Invalid appended page order');
          let raw=0,active=0,standard=0;const ids=new Set();
          for(const page of batch){
            if(!Array.isArray(page.rawIds)||!Array.isArray(page.messages)||!page.rawIds.length||page.rawIds.length>200||page.messages.length>page.rawIds.length||page.rawRows!==page.rawIds.length)throw Error('Invalid appended page');
            const pageIds=new Set(page.rawIds);
            for(const id of page.rawIds){if(typeof id!=='string'||!id||ids.has(id))throw Error('Repeated appended ID');ids.add(id);}
            const activeIds=new Set();for(const row of page.messages){if(!pageIds.has(row.id)||activeIds.has(row.id))throw Error('Invalid appended message identity');activeIds.add(row.id);if(['user','human','bot','assistant','character'].includes(row.role))standard++;}
            raw+=page.rawIds.length;active+=page.messages.length;
          }
          if(next.rawUniqueCount!==old.rawUniqueCount+raw||next.allActiveCount!==old.allActiveCount+active||next.standardCount!==old.standardCount+standard||next.complete!==false)throw Error('Invalid appended counts');
          batch.forEach((page,i)=>pages.add({...page,jobId:next.jobId},[scope.key,old.pages+i+1]));
          jobs.put({...next,checkpointAt:Date.now()},scope.key);result={revision:next.revision};return;
        }
        if (action !== 'commit') throw Error('Unknown checkpoint operation');
        const next = message.job;
        const base = Number(old?.revision || 0);
        if (!next || typeof next.jobId !== 'string' || next.jobId.length > 100 || next.revision !== base+1 ||
            (old && old.jobId !== next.jobId) || next.pages !== Number(old?.pages || 0)+(message.page?1:0)) throw Error('Export checkpoint changed in another tab; reopen to resume');
        if (message.page) {
          if (!Array.isArray(message.page.rawIds) || !Array.isArray(message.page.messages) || message.page.rawIds.length > 200 || message.page.messages.length > 200) throw Error('Invalid checkpoint page');
          pages.add({...message.page,jobId:next.jobId},[scope.key,next.pages]);
        }
        jobs.put({...next,checkpointAt:Date.now()},scope.key); result={revision:next.revision};
      } catch(error) { abort(error); }
    };
  });
}

// Local generation research. Separate from synced preferences, chat exports and
// large-data backups; no content, credentials, conversation or server message IDs.
let dsqQuotaDbPromise;
const DSQ_QUOTA_WINDOW = 86400000;
const DSQ_QUOTA_RETENTION = 14 * DSQ_QUOTA_WINDOW;
// The reference window is a display aid, never a server reset. State is
// derived from timestamped observations and committed with the event ledger.
const DSQ_QUOTA_CYCLE_SCHEMA = 3;
const DSQ_QUOTA_SUSTAINED = 10; // Heuristic, not a confirmed full reset.
const DSQ_QUOTA_CAPS = {free:2000,paid_minimal:2000,paid_basic:5000,paid_premium:5000};
function dsqQuotaCycleEmpty(){return {version:DSQ_QUOTA_CYCLE_SCHEMA,lastAt:0,lastId:'',totalSuccess:0,usage:0,usageStart:null,usageStartKind:'tracking',lastSuccess:null,lastRestriction:null,episode:null,priorEpisode:null,tier:null};}
function dsqQuotaApplyCycle(state,row){
  const at=row.at;
  state.lastAt=at;state.lastId=row.id;
  if(row.outcome==='reset-estimate'){state.usage=0;state.usageStart=at;state.usageStartKind='manual';state.cycleReason='manual-estimate-reset';return state;}
  if(DSQ_QUOTA_CAPS[row.tier])state.tier=row.tier;
  const cap=DSQ_QUOTA_CAPS[state.tier]||null;
  if(row.outcome==='success'){
    state.totalSuccess++;state.usage++;state.lastSuccess=at;
    if(!state.usageStart)state.usageStart=at;
    const e=state.episode;
    if(e){
      if(e.active)state.cycleReason='observed-recovery';e.active=false;e.firstRecoveryAt??=at;e.lastRecoveryAt=at;e.successes++;
      e.consecutive++;
      // A sustained run supports a *display* cycle boundary, not a verified
      // reset. Keep the earlier 1–2 successes, and retain the ledger.
      if(e.consecutive>=DSQ_QUOTA_SUSTAINED&&!e.sustainedAt){
        e.sustainedAt=at;
        state.cycleReason='sustained-recovery';if(state.usageStartKind!=='manual'&&(e.quotaEvidence||state.usageStartKind==='tracking')){state.usage=e.successes;state.usageStart=e.firstRecoveryAt;state.usageStartKind='sustained-recovery';}
      }
    }
    return state;
  }
  if(row.restriction!=='yes')return state;
  const notice=row.source==='native-limit-notice';
  const prior=state.episode;
  const explicit=notice&&[2000,5000].includes(row.limit);
  // No generic 429 is proof of quota exhaustion. Full observed usage plus
  // rejection is sufficient for a suspected quota, even without a banner.
  const reached=!!cap&&((state.usage>=cap&&state.usageStart&&at-state.usageStart<=DSQ_QUOTA_WINDOW)||
    (prior?.successes>=cap&&prior.sustainedAt));
  // A quota-sized observed recovery run is stronger evidence than an old
  // elapsed reference window. Never require the whole run to fit in 24h.
  const newCycle=!!prior&&!!cap&&!prior.active&&((prior.successes>=cap&&prior.sustainedAt)||(prior.sustainedAt&&state.usageStartKind==='sustained-recovery'&&state.usage>=cap&&state.usageStart));
  // A later restriction after sustained recovery without a full allowance is
  // ambiguous: retain historical episode, but do not reuse its expired clock.
  const newAmbiguous=!!prior&&prior.sustainedAt&&!prior.active&&!newCycle;
  if(!prior||newCycle||newAmbiguous){
    if(prior)state.priorEpisode={...prior};
    state.cycleReason=newCycle?'full-observed-allowance':newAmbiguous?'restriction-after-sustained-recovery':'initial-restriction';
    state.episode={id:row.id,start:at,firstRecoveryAt:null,lastRecoveryAt:null,sustainedAt:null,successes:0,consecutive:0,active:true,quotaEvidence:null,quotaNoticeAt:null,lastRejectionAt:null,lastRestrictionAt:at,newCycle:!!newCycle,uncertainAnchor:!!newAmbiguous};
  }else state.cycleReason=prior.active?'repeated-rejection':'partial-recovery-restricted';
  const e=state.episode;
  // A later banner may establish the nature of an earlier rejection, but
  // never interpret the native midnight text as a reset timestamp.
  if(explicit){e.quotaEvidence='native-notice';e.quotaNoticeAt??=at;}
  else if((newCycle||(!e.uncertainAnchor&&reached))&&!e.quotaEvidence)e.quotaEvidence='observed-ceiling';
  if(explicit&&!e.anchorUnverified)e.uncertainAnchor=false;
  e.active=true;e.consecutive=0;e.lastRestrictionAt=at;
  if(!notice)e.lastRejectionAt=at;
  state.lastRestriction={at,code:row.code,status:row.status,headers:row.headers||{},source:row.source||'network',limit:row.limit||null};
  return state;
}
function dsqQuotaCycleAppend(meta,row){
  const state=meta.cycle;
  if(state?.version!==DSQ_QUOTA_CYCLE_SCHEMA||meta.cycleDirty||row.at<state.lastAt||(row.at===state.lastAt&&row.id<=state.lastId))return {...meta,cycleDirty:true};
  return {...meta,cycle:dsqQuotaApplyCycle(state,row)};
}
// Upgrade in place, replaying only once (or on an out-of-order observation).
// A single transaction prevents a concurrent event from being lost.
async function dsqQuotaEnsureCycle(db,account,now){
  return new Promise((resolve,reject)=>{
    const tx=db.transaction(['events','accounts'],'readwrite'),a=tx.objectStore('accounts'),g=a.get(account);let result;
    g.onsuccess=()=>{
      const meta=g.result||{account,trackingStart:now};
      if(meta.cycle?.version===DSQ_QUOTA_CYCLE_SCHEMA&&!meta.cycleDirty){result=meta;return;}
      const state=dsqQuotaCycleEmpty();if(DSQ_QUOTA_CAPS[meta.tier])state.tier=meta.tier;const r=tx.objectStore('events').index('accountAt').openCursor(dsqQuotaRange([account],0,Number.MAX_SAFE_INTEGER));
      r.onsuccess=()=>{const c=r.result;if(c){dsqQuotaApplyCycle(state,c.value);c.continue();return;}
        // Sparse legacy evidence cannot establish whether an expired anchor belongs to the current cycle.
        const sparseLegacy=meta.cycle?.version===2&&state.episode?.active&&state.episode.firstRecoveryAt&&state.episode.start+DSQ_QUOTA_WINDOW<=now&&state.totalSuccess<(DSQ_QUOTA_CAPS[state.tier]||2000);
        const uncertainId=sparseLegacy?state.episode.id:meta.uncertainCycleId;
        if(uncertainId&&state.episode?.id===uncertainId){state.episode.anchorUnverified=true;state.episode.uncertainAnchor=true;state.cycleReason='legacy-incomplete-cycle-evidence';}
        result={...meta,uncertainCycleId:uncertainId||null,scopeLabel:meta.scopeLabel||crypto.randomUUID(),cycle:state,cycleDirty:false};a.put(result);};
    };
    tx.oncomplete=()=>resolve(result);tx.onabort=tx.onerror=()=>reject(tx.error||Error('Generation cycle migration failed'));
  });
}
function dsqQuotaOpen(){
  if(dsqQuotaDbPromise)return dsqQuotaDbPromise;
  dsqQuotaDbPromise=new Promise((resolve,reject)=>{
    const r=indexedDB.open('dsq-generation-observations-v1',1);
    r.onupgradeneeded=()=>{
      const events=r.result.createObjectStore('events',{keyPath:['account','id']});
      events.createIndex('accountAt',['account','at']);
      events.createIndex('outcomeAt',['account','outcome','at']);
      events.createIndex('restrictionAt',['account','restriction','at']);
      r.result.createObjectStore('accounts',{keyPath:'account'});
    };
    r.onsuccess=()=>{const db=r.result;db.onversionchange=()=>{db.close();dsqQuotaDbPromise=null;};resolve(db);};
    r.onerror=r.onblocked=()=>reject(Error('Generation observation storage unavailable'));
  }).catch(e=>{dsqQuotaDbPromise=null;throw e;});
  return dsqQuotaDbPromise;
}
function dsqQuotaSanitize(raw,account,now=Date.now()){
  if(!raw||typeof raw.id!=='string'||!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(raw.id)||
     !Number.isSafeInteger(raw.at)||!Number.isSafeInteger(raw.startedAt)||raw.startedAt>raw.at||raw.at>now+60000||raw.at<now-DSQ_QUOTA_RETENTION||
     !['success','failed','unconfirmed'].includes(raw.outcome)||!Number.isInteger(raw.status)||raw.status<0||raw.status>599||
     (raw.outcome==='success'&&!(raw.status>=200&&raw.status<300)))throw Error('Invalid generation observation');
  const code=typeof raw.code==='string'&&/^SC-\d{3}-\d{4}$/.test(raw.code)?raw.code:null;
  const headers={};
  for(const name of ['retry-after','ratelimit-limit','ratelimit-remaining','ratelimit-reset','x-ratelimit-limit','x-ratelimit-remaining','x-ratelimit-reset']){
    const v=raw.headers?.[name];
    if(typeof v==='string'&&(/^\d{1,12}$/.test(v)||(name==='retry-after'&&/^[A-Z][a-z]{2}, \d{2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2} GMT$/.test(v)&&Number.isFinite(Date.parse(v)))))headers[name]=v;
  }
  const restriction=raw.status===429||code==='SC-001-5201'?'yes':'no';
  const outcome=restriction==='yes'?'failed':raw.outcome;
  return {account,id:raw.id.toLowerCase(),at:raw.at,startedAt:raw.startedAt,status:raw.status,outcome,code,restriction,headers,
    kind:['normal','regeneration','continuation','unknown'].includes(raw.kind)?raw.kind:'unknown',
    reason:outcome==='unconfirmed'&&['stream-not-observed','body-not-observed','response-unavailable','unrecognized-response'].includes(raw.reason)?raw.reason:null,
    tier:['free','paid_minimal','paid_basic','paid_premium'].includes(raw.tier)?raw.tier:null};
}
function dsqQuotaRange(prefix,from,to){return IDBKeyRange.bound([...prefix,from],[...prefix,to]);}
// A single ordered worker lane coordinates alias binding with ledger writes.
// IDB commits still provide durability and atomicity across worker restarts.
let dsqQuotaLane=Promise.resolve();
async function dsqQuotaTraceState(m,s,trigger){
  const subscribed=typeof qolDiagnosticHasSubscribers==='function'&&qolDiagnosticHasSubscribers('normal');
  if(!subscribed&&m.quotaDiagnostic!==true)return;
  try{
    const v=await dsqQuotaMessageInner({...m,action:'summary'},s),e=v.episode;
    if(subscribed)qolBackgroundTrace('quota-state','generation-quota',{scope:v.scopeLabel,tier:v.tier,tierEvidence:v.tierEvidence,ceiling:v.ceiling,retained:v.retained,retainedSuccess:v.retainedSuccess,observed24h:v.success,lifetime:v.lifetimeSuccess,estimatedUsage:v.observedUsage,coverage:v.coverage,coverageGaps:v.coverageGaps,scopeLinked:v.scopeLinked,restriction:e?.active?(e.quotaEvidence?'suspected-quota':'unknown-rate-limit'):'not-observed',cycleId:e?.id||null,initialRestriction:e?.start||null,latestRejection:e?.lastRejectionAt||null,deadline:e?.quotaEvidence&&!e.uncertainAnchor?e.start+DSQ_QUOTA_WINDOW:null,firstRecovery:e?.firstRecoveryAt||null,sustainedRecovery:e?.sustainedAt||null,recoverySuccesses:e?.successes||0,cycleReason:v.cycleReason,deduplicated:v.duplicates,removed:v.removed,trigger},{critical:!!e?.active||trigger!=='count-checkpoint'});
    // Return only to the requesting page; never publish another tab's account state as its own.
    if(m.quotaDiagnostic===true)return {...v,diagnosticTrigger:trigger};
  }catch{try{qolBackgroundTrace('quota-storage-error','generation-quota',{operation:'snapshot',outcome:'failed'},{critical:true});}catch{}}
}

function dsqQuotaMessage(m,s){const task=dsqQuotaLane.then(()=>dsqQuotaMessageInner(m,s));dsqQuotaLane=task.catch(()=>{});return task;}
async function dsqQuotaBind(db,alias,target,now){
  if(alias===target)return;
  await new Promise((resolve,reject)=>{
    const tx=db.transaction(['events','accounts'],'readwrite'),a=tx.objectStore('accounts'),e=tx.objectStore('events');
    let source,dest;const x=a.get(alias),y=a.get(target);
    x.onsuccess=()=>{source=x.result||{};};
    y.onsuccess=()=>{dest=y.result||{account:target,trackingStart:now};
      if(source?.aliasTarget===target)return;
      if(source?.aliasTarget||dest.aliasTarget){tx.abort();return;}
      let moved=0,duplicates=0;
      const r=e.index('accountAt').openCursor(dsqQuotaRange([alias],0,Number.MAX_SAFE_INTEGER));
      r.onsuccess=()=>{const c=r.result;if(c){const row=c.value,g=e.get([target,row.id]);g.onsuccess=()=>{if(!g.result){e.add({...row,account:target});moved++;}else duplicates++;c.delete();c.continue();};return;}
        a.put({...dest,scopeLabel:dest.scopeLabel||source.scopeLabel||crypto.randomUUID(),trackingStart:Math.min(dest.trackingStart||now,source.trackingStart||now),lastSavedReplyAt:Math.max(dest.lastSavedReplyAt||0,source.lastSavedReplyAt||0)||null,tier:(source.tierAt||0)>(dest.tierAt||0)?source.tier:dest.tier||source.tier||null,tierAt:Math.max(dest.tierAt||0,source.tierAt||0),tierEvidence:(source.tierAt||0)>(dest.tierAt||0)?source.tierEvidence:dest.tierEvidence||source.tierEvidence||null,coverageGaps:(dest.coverageGaps||0)+(source.coverageGaps||0),duplicates:(dest.duplicates||0)+(source.duplicates||0)+duplicates,removed:(dest.removed||0)+(source.removed||0),cycleDirty:true});
        a.put({account:alias,aliasTarget:target});
      };
    };
    tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error||Error('Account binding conflict or write failed'));
  });
}
async function dsqQuotaMessageInner(m,s){
  const url=new URL(s.url||s.tab?.url||'');
  if(s.id!==chrome.runtime.id||s.frameId!==0||url.protocol!=='https:'||!['spicychat.ai','www.spicychat.ai'].includes(url.hostname)||
    typeof m.accountKey!=='string'||!/^[0-9a-f]{64}$/.test(m.accountKey))throw Error('Verified account scope required');
  let account=m.accountKey;const now=Date.now(),db=await dsqQuotaOpen();
  if(m.action==='bind'){
    if(typeof m.canonicalKey!=='string'||!/^[0-9a-f]{64}$/.test(m.canonicalKey))throw Error('Invalid canonical scope');
    await dsqQuotaBind(db,account,m.canonicalKey,now);return {ok:true,quotaState:await dsqQuotaTraceState(m,s,'scope-linked')};
  }
  const link=await idbRequest(db.transaction('accounts').objectStore('accounts').get(account));
  if(link?.aliasTarget)account=link.aliasTarget;
  if(m.action==='scopeInfo'||m.action==='gap'){
    let changedState=false;
    const tier=Object.hasOwn(DSQ_QUOTA_CAPS,m.tier)?m.tier:null;
    await new Promise((resolve,reject)=>{const tx=db.transaction('accounts','readwrite'),a=tx.objectStore('accounts'),g=a.get(account);g.onsuccess=()=>{const prior=g.result||{account,trackingStart:now};const n=m.action==='gap'?Math.min(256,Math.max(1,Number(m.count)||1)):0;const changed=tier&&tier!==prior.tier;if(n||changed||!prior.scopeLabel){changedState=true;a.put({...prior,scopeLabel:prior.scopeLabel||crypto.randomUUID(),coverageGaps:(prior.coverageGaps||0)+n,tier:tier||prior.tier||null,tierAt:changed?now:prior.tierAt||0,tierEvidence:tier?(m.tierEvidence==='native-header'?'native-header':'native-profile'):prior.tierEvidence||null});}};tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error||Error('Coverage write failed'));});return {ok:true,quotaState:changedState?await dsqQuotaTraceState(m,s,m.action==='gap'?'coverage-gap':'tier-change'):undefined};
  }
  if(m.action==='record'){
    const row=dsqQuotaSanitize(m.event,account,now);
    let inserted=false,traceReason=null;
    await new Promise((resolve,reject)=>{
      const tx=db.transaction(['events','accounts'],'readwrite'),events=tx.objectStore('events'),accounts=tx.objectStore('accounts');
      const r=events.get([account,row.id]);
      r.onsuccess=()=>{const duplicate=!!r.result;if(!duplicate){events.add(row);inserted=true;}const a=accounts.get(account);a.onsuccess=()=>{const prior=a.result||{account,trackingStart:row.startedAt};const base={...prior,scopeLabel:prior.scopeLabel||crypto.randomUUID(),trackingStart:Math.min(prior.trackingStart||row.startedAt,row.startedAt),tier:(!duplicate&&row.at>=(prior.tierAt||0)?row.tier:null)||prior.tier||null,tierAt:!duplicate&&row.tier&&row.at>=(prior.tierAt||0)?row.at:prior.tierAt||0,tierEvidence:(!duplicate&&row.tier&&row.at>=(prior.tierAt||0))?'native-header':prior.tierEvidence||null};if(duplicate){accounts.put({...base,duplicates:(prior.duplicates||0)+1});traceReason='deduplicated';return;}const before=base.cycle?{active:base.cycle.episode?.active,sustained:base.cycle.episode?.sustainedAt,id:base.cycle.episode?.id,tier:base.cycle.tier}:null;if(base.cycle&&base.tier)base.cycle.tier=base.tier;const next=dsqQuotaCycleAppend(base,row);accounts.put(next);const after=next.cycle;if(row.restriction==='yes'||!before||next.cycleDirty||before.active!==after?.episode?.active||before.sustained!==after?.episode?.sustainedAt||before.id!==after?.episode?.id||before.tier!==after?.tier)traceReason='state-change';else if(after?.totalSuccess%100===0)traceReason='count-checkpoint';};};
      tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error||Error('Observation write failed'));
    });
    if(inserted)try{qolBackgroundTrace('generation-observation','generation-quota',{at:row.at,startedAt:row.startedAt,status:row.status,outcome:row.outcome,code:row.code,kind:row.kind,tier:row.tier,headers:row.headers,reason:row.reason});}catch{}
    const quotaState=traceReason?await dsqQuotaTraceState(m,s,traceReason):undefined;
    return {ok:true,inserted,quotaState};
  }
  if(m.action==='historyTime'){
    // This is historical reply evidence, not a charged generation or recovery.
    if(!Number.isSafeInteger(m.replyAt)||m.replyAt<=now-DSQ_QUOTA_RETENTION||m.replyAt>now)throw Error('Invalid historical reply timestamp');
    await new Promise((resolve,reject)=>{
      const tx=db.transaction('accounts','readwrite'),a=tx.objectStore('accounts'),g=a.get(account);
      g.onsuccess=()=>{const prior=g.result||{account,trackingStart:now};if(m.replyAt>(prior.lastSavedReplyAt||0))a.put({...prior,lastSavedReplyAt:m.replyAt});};
      tx.oncomplete=resolve;tx.onerror=tx.onabort=()=>reject(tx.error||Error('Historical timestamp write failed'));
    });return {ok:true};
  }
  if(m.action==='nativeNotice'){
    // An explicit native limit banner is an observation, not an HTTP request.
    // Serialize read/check/write so concurrent tabs cannot restart the same notice.
    if(![2000,5000].includes(m.limit))throw Error('Invalid native limit notice');
    let inserted=false;
    await new Promise((resolve,reject)=>{
      const tx=db.transaction(['events','accounts'],'readwrite'),e=tx.objectStore('events'),a=tx.objectStore('accounts'),idx=e.index('outcomeAt');
      const r=idx.openCursor(dsqQuotaRange([account,'success'],0,now+60000),'prev');
      r.onsuccess=()=>{
        const since=(r.result?.value?.at||0)+1;
        const n=idx.openCursor(dsqQuotaRange([account,'notice'],0,now+60000),'prev');
        n.onsuccess=()=>{
          if(n.result?.value?.at>=since)return;
          // A stale banner after an observed recovery must not create another
          // episode merely because the editor reloaded or another tab opened.
          if(r.result&&m.fresh!==true){
            const later=e.index('restrictionAt').openCursor(dsqQuotaRange([account,'yes'],since,now+60000),'next');
            later.onsuccess=()=>{if(later.result)insert();};
          }else insert();
        };
        function insert(){
          const row={account,id:crypto.randomUUID(),at:now,startedAt:now,status:null,outcome:'notice',code:null,restriction:'yes',headers:{},kind:'unknown',reason:null,tier:null,source:'native-limit-notice',limit:m.limit};
          e.add(row);inserted=true;
          const g=a.get(account);g.onsuccess=()=>{const prior=g.result||{account,trackingStart:now};a.put(dsqQuotaCycleAppend({...prior,trackingStart:Math.min(prior.trackingStart||now,now)},row));};
        }
      };
      tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error||Error('Native restriction observation write failed'));
    });
    return {ok:true,inserted,quotaState:inserted?await dsqQuotaTraceState(m,s,'native-limit-notice'):undefined};
  }
  if(m.action==='resetEstimate'){
    await new Promise((resolve,reject)=>{const tx=db.transaction(['events','accounts'],'readwrite'),a=tx.objectStore('accounts'),e=tx.objectStore('events'),g=a.get(account);g.onsuccess=()=>{const prior=g.result||{account,trackingStart:now};const row={account,id:crypto.randomUUID(),at:now,startedAt:now,outcome:'reset-estimate',restriction:'no',tier:null};e.add(row);a.put(dsqQuotaCycleAppend(prior,row));};tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error||Error('Estimate reset failed'));});return {ok:true,quotaState:await dsqQuotaTraceState(m,s,'manual-estimate-reset')};
  }
  if(m.action==='clear'){
    await new Promise((resolve,reject)=>{
      const tx=db.transaction(['events','accounts'],'readwrite');const index=tx.objectStore('events').index('accountAt');
      const a=tx.objectStore('accounts'),g=a.get(account);let removed=0;
      g.onsuccess=()=>{const r=index.openCursor(dsqQuotaRange([account],0,Number.MAX_SAFE_INTEGER));r.onsuccess=()=>{const c=r.result;if(c){c.delete();removed++;c.continue();return;}a.put({account,scopeLabel:g.result?.scopeLabel||crypto.randomUUID(),trackingStart:now,tier:g.result?.tier||null,tierEvidence:g.result?.tierEvidence||null,removed:(g.result?.removed||0)+removed,duplicates:g.result?.duplicates||0,cycle:dsqQuotaCycleEmpty(),coverageGaps:0});};};tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error||Error('Observation clear failed'));
    });return {ok:true,quotaState:await dsqQuotaTraceState(m,s,'manual-history-clear')};
  }
  if(m.action==='export'){
    const tx=db.transaction('events'),r=tx.objectStore('events').index('accountAt').getAll(dsqQuotaRange([account],0,now+60000));
    const rows=await idbRequest(r);return {ok:true,events:rows.map(({account,...event})=>event)};
  }
  if(m.action!=='summary')throw Error('Unknown research operation');
  // Indexed rolling counts remain separate from the durable cycle estimate.
  // No time-based deletion or resets. Older versions' pruned rows are not recoverable.
  await dsqQuotaEnsureCycle(db,account,now);
  const tx=db.transaction(['events','accounts']),events=tx.objectStore('events'),outcomes=events.index('outcomeAt');
  const [success,failed,unconfirmed,current,retained]=await Promise.all([
    ...['success','failed','unconfirmed'].map(kind=>idbRequest(outcomes.count(dsqQuotaRange([account,kind],now-DSQ_QUOTA_WINDOW,now+60000)))),
    idbRequest(tx.objectStore('accounts').get(account)),idbRequest(events.index('accountAt').count(dsqQuotaRange([account],0,Number.MAX_SAFE_INTEGER)))
  ]);
  const cycle=current?.cycle||dsqQuotaCycleEmpty(),episode=cycle.episode;
  const tier=current?.tier||cycle.tier||null;
  // The cycle replay counts retained successes only. Historical pruning and
  // explicit clears make an all-time lifetime count unrecoverable. totalSuccess
  // remains a compatibility alias; do not label it lifetime in diagnostics.
  return {ok:true,success,failed,unconfirmed,retained,scopeLinked:!!link?.aliasTarget,scopeLabel:current?.scopeLabel||null,tier,tierEvidence:current?.tierEvidence||null,ceiling:DSQ_QUOTA_CAPS[tier]||null,coverageGaps:current?.coverageGaps||0,duplicates:current?.duplicates||0,removed:current?.removed||0,cycleReason:cycle.cycleReason||null,observedUsage:cycle.usage,retainedSuccess:cycle.totalSuccess,lifetimeSuccess:null,totalSuccess:cycle.totalSuccess,usageStart:cycle.usageStart,usageStartKind:cycle.usageStartKind,
    lastSuccess:cycle.lastSuccess,lastRestriction:cycle.lastRestriction,episode,priorEpisode:cycle.priorEpisode,
    episodeStart:episode?.start||null,episodeRequestAt:null,quotaNoticeAt:episode?.quotaNoticeAt||null,firstSuccessAfterRestriction:episode?.firstRecoveryAt||null,
    lastSavedReplyAt:current?.lastSavedReplyAt||null,trackingStart:current?.trackingStart||now,coverage:'partial',retentionDays:null};
}

// This is a private app-owned origin, never the live website or a desktop
// service worker. Sender URLs are supplied by the native trusted-document
// bridge; a website message cannot choose the Settings sender.
const chrome = Object.freeze({runtime:Object.freeze({id:'spicychat-qol-android', getURL: path => 'https://qol-android-storage.invalid/'+path})});
const qolBackgroundTrace = () => {};
globalThis.__qolPrivateDispatch = async (key,id,raw,url,settings) => {
  let result;
  try {
    const m=JSON.parse(raw);
    const s={id:chrome.runtime.id,frameId:0,url:settings?chrome.runtime.getURL('options.html'):url,tab:{id:1,url}};
    if(settings){
      if(m.type!=='DS_CHAT_EXPORT_CHECKPOINT'||!['settings-overview','settings-clear'].includes(m.action))throw Error('Invalid Settings operation');
      result=await dsqChatExportCheckpoint(m,s);
    }else if(m.type==='DS_GENERATION_QUOTA_RESEARCH'){
      m.quotaDiagnostic=false;
      result=await dsqQuotaMessage(m,s);
    }else if(m.type==='DS_CHAT_EXPORT_CHECKPOINT'&&!String(m.action).startsWith('settings-')){
      result=await dsqChatExportCheckpoint(m,s);
    }else throw Error('Unsupported private storage operation');
    const serialized=JSON.stringify(result);
    if(serialized.length>16*1024*1024)throw Error('Private storage response exceeds bounded size; saved data retained');
    QolPrivateReceipt.complete(key,id,serialized);
  }catch(error){QolPrivateReceipt.complete(key,id,JSON.stringify({ok:false,error:String(error?.message||'Private storage failed').slice(0,250)}));}
};

})();
