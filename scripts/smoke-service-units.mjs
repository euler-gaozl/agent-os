// Every deployment unit is exercised against disposable CI data. Provider and
// OTLP endpoints are controlled fixtures, never paid production credentials.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
const exec=(program,args,timeout=180000)=>execFileSync(program,args,{encoding:'utf8',timeout,stdio:['pipe','pipe','pipe']}).trim();
const docker=(...args)=>exec('docker',args);
const dc=(...args)=>docker('compose','-f','compose.yaml','-f','deploy/compose.ci.yaml',...args);
const admin=JSON.parse(fs.readFileSync('.state/services/control.json','utf8')).ADMIN_TOKEN;
const business=JSON.parse(fs.readFileSync('.state/services/futures.json','utf8')).BUSINESS_TOKEN;
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const report={checks:[],limits:'Lifecycle/contract scenario with additional optional services and replicas; not a complete 2 CPU platform capacity test.'};
const configHashes=()=>Object.fromEntries(fs.readdirSync('.state/services').filter(x=>x.endsWith('.json')).sort().map(x=>[x,createHash('sha256').update(fs.readFileSync('.state/services/'+x)).digest('hex')]));
const originalConfigs=configHashes();
const isolatedTelemetryConfig=path.resolve('.state/ci-telemetry-isolated.json');
async function api(route,body,biz=false){const r=await fetch(`http://127.0.0.1:${biz?8098:8090}/api`+route,{method:body?'POST':'GET',headers:{Authorization:'Bearer '+(biz?business:admin),'Content-Type':'application/json',...(body&&biz?{'Idempotency-Key':'independent-worker-fixture'}:{})},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(12000)});assert(r.ok,'API contract rejected '+route);return r.json()}
async function until(fn,label){for(let i=0;i<80;i++){try{if(await fn())return}catch{}await sleep(500)}throw Error('Timeout: '+label)}
function snapshot(exclude=[]){const ids=dc('ps','-q').split('\n').filter(x=>x&&!exclude.includes(x));return JSON.parse(docker('inspect',...ids)).map(c=>({id:c.Id,started:c.State.StartedAt,restarts:c.RestartCount})).sort((a,b)=>a.id.localeCompare(b.id))}
try{
 if(process.env.GITHUB_ACTIONS!=='true'||process.env.POSTGRES_PASSWORD!=='disposable-ci-database-only')throw Error('Independent database fixture requires disposable GitHub CI');
 dc('exec','-T','postgres','psql','-U','agentos','-d','agentos','-v','ON_ERROR_STOP=1','-c','CREATE DATABASE agentos_telemetry_ci');
 const telemetryConfig=JSON.parse(fs.readFileSync('.state/services/telemetry.json','utf8'));
 const telemetryDB=new URL(telemetryConfig.DATABASE_URL);telemetryDB.pathname='/agentos_telemetry_ci';telemetryConfig.DATABASE_URL=telemetryDB.href;
 const migrationDB=new URL(telemetryDB);migrationDB.username='agentos';migrationDB.password=process.env.POSTGRES_PASSWORD;
 dc('run','--rm','--no-deps','-e','DATABASE_URL='+migrationDB.href,'migrate','--service','telemetry');
 fs.writeFileSync(isolatedTelemetryConfig,JSON.stringify(telemetryConfig),{mode:0o640});
 exec('sudo',['chown','10001:'+exec('id',['-g']),isolatedTelemetryConfig]);
 assert.equal(dc('exec','-T','postgres','psql','-U','agentos','-d','agentos_telemetry_ci','-At','-c',"SELECT to_regclass('events') IS NULL AND to_regclass('runs') IS NULL"),'t');
 assert.equal(dc('exec','-T','postgres','psql','-U','agentos','-d','agentos','-At','-c',"SELECT has_table_privilege('agentos_telemetry','events','SELECT')"),'f');
 await api('/credentials',{name:'LANGFUSE_PUBLIC_KEY',value:'ci-public'});
 await api('/credentials',{name:'LANGFUSE_SECRET_KEY',value:'ci-secret'});
 dc('up','-d','--no-deps','--wait','sandbox','telemetry');
 const network=Object.keys(JSON.parse(docker('inspect',dc('ps','-q','registry')))[0].NetworkSettings.Networks)[0];
 for(const role of ['registry','toolhub','storage','runtime','indexer','sources','sandbox','telemetry','worker','control','futures']){
  const project='agentos-ci-unit-'+role,ids=dc('ps','-q',role).split('\n').filter(Boolean),others=snapshot(ids);
  assert(ids.length>0);
  dc('stop',role);dc('rm','-f',role);
  if(role==='telemetry')dc('exec','-T','postgres','psql','-U','agentos','-d','agentos','-v','ON_ERROR_STOP=1','-c',"INSERT INTO events(run_id,kind,payload) SELECT id,'ci_telemetry_isolated','{}' FROM runs ORDER BY created_at LIMIT 1");
  const args=['scripts/release-service.mjs','deploy','--project',project,'--service',role,'--image',`agent-os-${role}:${role==='sources'?'0.6.0':'0.5.0'}`,'--config',role==='telemetry'?isolatedTelemetryConfig:path.resolve('.state/services/'+role+'.json'),'--network',network,'--replicas',String(ids.length)];
  if(role==='control'||role==='futures')args.push('--publish',role==='control'?'8090':'8098');
  try{
   const receipt=JSON.parse(exec(process.execPath,args));
   await until(async()=>{const catalog=await api('/catalog');return catalog.services.registry&&catalog.services.toolhub&&catalog.items.some(x=>x.id==='ci-agent'&&x.summary)},role+' catalog through shared Console');
   const history=await api('/tasks',undefined,true);assert(history.some(x=>x.status==='completed'));
   const search=await api('/knowledge/query',{knowledge:{id:'ci-kb',revision:1},query:'甲醇库存'});assert.equal(search.hits.length,1);
   if(role==='worker'){
    const run=await api('/tasks',{agent:{id:'ci-agent',revision:1},commodity:'CI fixture',period:'independent worker unit',question:'Verify separately deployed worker'},true);
    await until(async()=>{const r=await api('/tasks/'+run.id,undefined,true);return r.status==='completed'},'task executed by independent worker replicas');
    assert.match((await api('/tasks/'+run.id,undefined,true)).result,/Controlled/);
    const calls=await api('/runs/'+run.id+'/calls');
    assert.equal(calls.filter(x=>x.kind==='tool'&&x.status==='completed').length,4);
   }
   if(role==='telemetry'){
    await until(()=>Number(dc('exec','-T','postgres','psql','-U','agentos','-d','agentos_telemetry_ci','-At','-c',"SELECT count(*) FROM telemetry_inbox WHERE kind='ci_telemetry_isolated' AND exported_at IS NOT NULL"))===1,'durable OTLP fixture export from independent database');
   }
   assert.deepEqual(snapshot(),others,'unrelated container ID/start time/restart count changed');
   assert.deepEqual(configHashes(),originalConfigs);
   report.checks.push({service:role,image:receipt.image,replicas:receipt.replicas,independent_start:true,shared_console:true,other_containers_unchanged:true,...(role==='telemetry'?{separate_database:true,no_execution_sql_permission:true}: {})});
   console.log('PASS independent '+role+' deployment with existing service identities and shared Console');
  }finally{
   const own=docker('ps','-aq','--filter','label=com.docker.compose.project='+project).split('\n').filter(Boolean);
   if(own.length)docker('rm','-f',...own);
   dc('up','-d','--no-deps','--wait',role);
  }
 }
}finally{
 fs.writeFileSync('.state/ci-evidence/all-service-units.json',JSON.stringify(report,null,2));
}
