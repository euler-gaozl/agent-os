// Actual running services under aggregate cgroup caps. The external model/MCP/
// OTLP fixture is excluded and explicitly labelled; no paid credentials used.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {overlapDuration} from './lib/load-window.mjs';
const exec=promisify(execFile);
const run=async(program,args)=>(await exec(program,args,{encoding:'utf8',timeout:120000,maxBuffer:4<<20})).stdout.trim();
const dc=(...args)=>run('docker',['compose','-f','compose.yaml','-f','deploy/compose.ci.yaml',...args]);
const docker=(...args)=>run('docker',args);
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const percentile=(v,p)=>[...v].sort((a,b)=>a-b)[Math.min(v.length-1,Math.floor(v.length*p))];
if(process.env.GITHUB_ACTIONS!=='true'||process.env.POSTGRES_PASSWORD!=='disposable-ci-database-only')throw Error('Only the disposable CI project may run this test');
const config=role=>JSON.parse(fs.readFileSync('.state/services/'+role+'.json','utf8'));
const admin=config('control').ADMIN_TOKEN,business=config('futures').BUSINESS_TOKEN;
const evidence={version:1,scope:'All platform services, PostgreSQL and two DSH workers; controlled remote model/MCP/OTLP fixture excluded. Sandbox broker enabled; code execution workloads excluded.',criteria:{cpu_caps:2,memory_caps_bytes:4*1024**3,tasks:12,task_deadline_seconds:180,read_load_seconds:90,read_clients:4,read_interval_ms:100,minimum_success_fraction:.95,p95_read_ms:1000,unexpected_5xx:0},containers:[],requests:[],resources:[],tasks:[]};
const api=async(route,body,biz=false,key)=>{
 const response=await fetch(`http://127.0.0.1:${biz?8098:8090}/api`+route,{method:body?'POST':'GET',headers:{Authorization:'Bearer '+(biz?business:admin),'Content-Type':'application/json',...(key?{'Idempotency-Key':key}:{})},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(12000)});
 const value=await response.json();return {status:response.status,value};
};
const bytes=s=>{const m=s.match(/^([\d.]+)(B|KiB|MiB|GiB)$/);assert(m,'Unknown Docker memory unit');return Number(m[1])*({B:1,KiB:1024,MiB:1024**2,GiB:1024**3}[m[2]])};
let stop=false,sampler;
try{
 await dc('--profile','sandbox','--profile','telemetry','up','-d','--wait','--wait-timeout','120');
 const ids=(await dc('ps','-q')).split('\n').filter(Boolean);
 const inspected=JSON.parse(await docker('inspect',...ids)).filter(x=>x.Config.Labels['com.docker.compose.service']!=='fixture');
 evidence.containers=inspected.map(c=>({id:c.Id,service:c.Config.Labels['com.docker.compose.service'],cpu_cap:c.HostConfig.NanoCpus/1e9,memory_cap_bytes:c.HostConfig.Memory,restarts_before:c.RestartCount}));
 assert.equal(new Set(evidence.containers.map(x=>x.service)).size,13,'12 service roles plus PostgreSQL must run');
 const cpu=evidence.containers.reduce((a,c)=>a+c.cpu_cap,0),memory=evidence.containers.reduce((a,c)=>a+c.memory_cap_bytes,0);
 assert(evidence.containers.every(x=>x.cpu_cap>0&&x.memory_cap_bytes>0),'No unbounded platform container');
 assert(cpu<=2.00001&&memory<=4*1024**3,'Aggregate enforced budget exceeded');
 evidence.enforced={cpu,memory_bytes:memory};
 const platformIDs=evidence.containers.map(x=>x.id);
 sampler=(async()=>{while(!stop){try{
  const samples=(await docker('stats','--no-stream','--format','{{json .}}',...platformIDs)).split('\n').filter(Boolean).map(x=>JSON.parse(x));
  assert.equal(samples.length,platformIDs.length);
  evidence.resources.push({at:new Date().toISOString(),memory_bytes:samples.reduce((n,x)=>n+bytes(x.MemUsage.split(' / ')[0]),0),cpu_percent:samples.reduce((n,x)=>n+Number(x.CPUPerc.replace('%','')),0),containers:samples.map(x=>({id:x.ID,memory:x.MemUsage,cpu:x.CPUPerc,pids:Number(x.PIDs)}))});
 }catch{evidence.resource_errors=(evidence.resource_errors??0)+1}if(!stop)await sleep(2000)}})();
 await sleep(6000);
 const began=Date.now();evidence.read_clients=[];
 const readers=Array.from({length:evidence.criteria.read_clients},(_,client)=>(async()=>{
  const started=Date.now(),end=started+evidence.criteria.read_load_seconds*1000;let n=0;
  while(Date.now()<end){
   const route=(n+++client)%2?'/knowledge/query':'/catalog?limit=100';const start=performance.now();
   try{
    const response=await api(route,route==='/knowledge/query'?{knowledge:{id:'ci-kb',revision:1},query:'甲醇库存'}:undefined);
    evidence.requests.push({client,at_ms:Date.now()-began,route,status:response.status,ms:performance.now()-start});
    if(response.status===200&&route==='/knowledge/query')assert.equal(response.value.hits[0]?.source,'fixture://source');
   }catch{evidence.requests.push({client,at_ms:Date.now()-began,route,status:0,ms:performance.now()-start})}
   await sleep(evidence.criteria.read_interval_ms);
  }
  evidence.read_clients.push({client,started_ms:started-began,finished_ms:Date.now()-began,duration_ms:Date.now()-started,requests:n});
 })());
 const monitor=(async()=>{
 for(let i=0;i<evidence.criteria.tasks;i++){
  const response=await api('/tasks',{agent:{id:'ci-agent',revision:1},commodity:'CI fixture',period:'bounded-platform-'+i,question:'Verify sustained platform operation under bounded resources'},true,'bounded-platform-'+i);
  assert.equal(response.status,201);evidence.tasks.push({id:response.value.id,submitted_ms:Date.now()-began});
 }
 const pending=new Set(evidence.tasks.map(x=>x.id));while(pending.size){
  for(const id of [...pending]){
   const response=await api('/tasks/'+id,undefined,true);assert.equal(response.status,200);
   if(['failed','cancelled','waiting_unknown','needs_review'].includes(response.value.status)){
    // Record the cause before aborting the measurement. A terminal-state
    // assertion without the run/ledger made the f03111b failure untriageable.
    const diagnostic=await Promise.allSettled([api('/runs/'+id),api('/runs/'+id+'/calls'),api('/runs/'+id+'/events'),dc('logs','--no-color','--tail','150','worker','runtime','toolhub','storage')]);
    evidence.failure={task:id,business:response.value,diagnostic:diagnostic.map(x=>x.status==='fulfilled'?x.value:{error:String(x.reason)})};
    assert.fail('Agent failed under declared workload: '+response.value.status+'; cause retained in platform-budget.json');
   }
   if(response.value.status==='completed'){
    assert.match(response.value.result,/Controlled service contract test completed/);
    const calls=await api('/runs/'+id+'/calls');assert.equal(calls.status,200);
    assert.equal(calls.value.filter(x=>x.kind==='tool'&&x.status==='completed').length,4);
    const events=await api('/runs/'+id+'/events');assert.equal(events.status,200);
    const claims=events.value.filter(x=>x.kind==='claimed'),done=events.value.filter(x=>x.kind==='checkpoint'&&x.payload.status==='completed');
    assert.equal(claims.length,1,'This workload must have one uninterrupted execution lease');assert.equal(done.length,1);
    const item=evidence.tasks.find(x=>x.id===id);
    item.started_ms=Date.parse(claims[0].created_at)-began;item.completed_ms=Date.parse(done[0].created_at)-began;
    item.observed_completed_ms=Date.now()-began;item.elapsed_ms=item.completed_ms-item.submitted_ms;pending.delete(id);
   }
  }
  assert(Date.now()-began<evidence.criteria.task_deadline_seconds*1000,'Task deadline exceeded');if(pending.size)await sleep(1000);
 }})();
 const results=await Promise.allSettled([...readers,monitor]);for(const result of results)if(result.status==='rejected')throw result.reason;
 assert.equal(evidence.read_clients.length,evidence.criteria.read_clients);
 assert(evidence.read_clients.every(x=>x.duration_ms>=evidence.criteria.read_load_seconds*1000&&x.requests>0),'Every reader must actually run for the full declared window');
 const overlapStart=Math.max(...evidence.read_clients.map(x=>x.started_ms)),overlapEnd=Math.min(...evidence.read_clients.map(x=>x.finished_ms));
 evidence.overlap_basis='Union of persisted claimed-to-completed intervals, clipped to all readers; excludes gaps and polling delay. Same-host CI clocks.';
 evidence.mixed_load_overlap_ms=overlapDuration(evidence.tasks.map(x=>[x.started_ms,x.completed_ms]),overlapStart,overlapEnd);
 assert(evidence.mixed_load_overlap_ms>=10000,'Tasks and all read clients must overlap for at least ten seconds');
 stop=true;await sampler;
 const good=evidence.requests.filter(x=>x.status===200),other=evidence.requests.filter(x=>x.status!==200&&x.status!==429);
 evidence.summary={read_requests:evidence.requests.length,read_successes:good.length,read_429:evidence.requests.filter(x=>x.status===429).length,unexpected:other.length,p50_ms:percentile(good.map(x=>x.ms),.5),p95_ms:percentile(good.map(x=>x.ms),.95),peak_sampled_memory_bytes:Math.max(...evidence.resources.map(x=>x.memory_bytes)),max_task_elapsed_ms:Math.max(...evidence.tasks.map(x=>x.elapsed_ms))};
 assert(evidence.resources.length>=10&&!evidence.resource_errors,'Missing resource observations');
 assert.equal(other.length,0,'Unexpected response under declared workload');
 assert(good.length/evidence.requests.length>=.95&&evidence.summary.p95_ms<1000,'Read success/latency criterion failed');
 const final=JSON.parse(await docker('inspect',...platformIDs));
 for(const c of final){const before=evidence.containers.find(x=>x.id===c.Id);assert.equal(c.RestartCount,before.restarts_before,'Unexpected container restart');assert(!c.State.OOMKilled&&c.State.Health?.Status==='healthy','Container unhealthy/OOM after mixed workload')}
 evidence.passed=true;
 console.log(JSON.stringify({passed:true,enforced:evidence.enforced,summary:evidence.summary}));
}finally{
 stop=true;if(sampler)await sampler;
 fs.mkdirSync('.state/ci-evidence',{recursive:true});fs.writeFileSync('.state/ci-evidence/platform-budget.json',JSON.stringify(evidence,null,2));
}
