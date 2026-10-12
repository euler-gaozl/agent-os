// Independent owners + real PostgreSQL/process failures; model/MCP are synthetic.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {ports,domains,ownerOf} from './lib/owner-stack.mjs';
if(process.platform!=='linux'||process.env.GITHUB_ACTIONS!=='true'||process.env.RUNNER_ENVIRONMENT!=='github-hosted')throw Error('Disposable hosted Linux CI only');
const root=path.resolve('.state/owner-stack'),compose=path.join(root,'compose.json'),project='agentos-owner-ci';
const owners=JSON.parse(fs.readFileSync(path.join(root,'owners.json'),'utf8'));
const report={passed:false,checks:[],owners:Object.fromEntries(Object.entries(owners).map(([r,s])=>[r,{commit:s.commit,image:s.image}])),provider_calls:0,model:'Controlled synthetic fixture, not a paid supplier or futures fact',scope:'Fresh split databases, actual owner images and process/database faults; not historical upgrade, independent release controller crash, or machine HA'};
let phase='start';
const run=(program,args,options={})=>execFileSync(program,args,{encoding:'utf8',timeout:120000,stdio:['pipe','pipe','pipe'],...options}).trim();
const docker=(...args)=>run('docker',args);
const dc=(...args)=>docker('compose','-p',project,'-f',compose,...args);
const sql=(q,domain='runtime')=>dc('exec','-T','postgres','psql','-X','-U','provision_fixture','-d','agentos_owner_ci_'+domain,'-At','-v','ON_ERROR_STOP=1','-c',q);
const config=role=>JSON.parse(fs.readFileSync(path.join(root,'bootstrap',role+'.json'),'utf8'));
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const until=async(fn,label,seconds=100)=>{phase=label;const end=Date.now()+seconds*1000;while(Date.now()<end){if(await fn())return;await sleep(500)}throw Error('Timed out')};
const passed=name=>{report.checks.push(name);console.log('PASS '+name)};
const ids=role=>dc('ps','-q',...(role?[role]:[])).split('\n').filter(Boolean);
const info=id=>JSON.parse(docker('inspect',id))[0];
const health=role=>dc('exec','-T',role,owners[role].healthcheck);
const snapshot=exclude=>JSON.parse(docker('inspect',...ids().filter(id=>!exclude.includes(id)))).map(c=>({id:c.Id,start:c.State.StartedAt,restarts:c.RestartCount})).sort((a,b)=>a.id.localeCompare(b.id));
async function request(route,body,options={}){
 const response=await fetch('http://127.0.0.1:'+(options.business?8098:8090)+'/api'+route,{method:body===undefined?'GET':'POST',headers:{Authorization:'Bearer '+(options.business?config('futures').BUSINESS_TOKEN:config('control').ADMIN_TOKEN),'Content-Type':'application/json',...(options.key?{'Idempotency-Key':options.key}:{})},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(12000)});
 if(options.expect)assert.equal(response.status,options.expect,'Unexpected API status at '+route);
 else assert(response.ok,'Unexpected API failure at '+route);
 return response.json();
}
function internalRequest(role,route,token,body){
 const code="let t='';for await(const b of process.stdin)t+=b;const p=JSON.parse(t);const r=await fetch(p.url,{method:p.body===undefined?'GET':'POST',headers:{Authorization:'Bearer '+p.token,'Content-Type':'application/json'},body:p.body===undefined?undefined:JSON.stringify(p.body),signal:AbortSignal.timeout(10000)});console.log(JSON.stringify({status:r.status,body:await r.json()}));";
 return JSON.parse(run('docker',['compose','-p',project,'-f',compose,'exec','-T','fixture','node','--input-type=module','-e',code],{input:JSON.stringify({url:'http://'+role+':'+(role==='fixture'?8111:ports[role])+route,token,body})}));
}
function crash(role,id){
 const before=info(id).RestartCount;
 const command='target=""; count=0; for file in /proc/[0-9]*/comm; do name=""; IFS= read -r name < "$file" || continue; if [ "$name" = service ]; then pid=${file#/proc/}; pid=${pid%/comm}; target=$pid; count=$((count+1)); fi; done; [ "$count" = 1 ] || exit 4; kill -KILL "$target"';
 try{docker('exec','--user',owners[role].user,id,'/bin/sh','-c',command)}catch(e){if(e.status!==137)throw Error('Application crash command failed')}
 return before;
}
try{
 phase='config ownership and bytes';
 for(const [role,s] of Object.entries(owners)){
  const privateFile=path.join(root,'bootstrap',role+'.json'),deployed=path.join(root,'services',role+'.json'),stat=fs.statSync(deployed);
  assert.equal(stat.uid,Number(s.uid));assert.equal(stat.mode&0o777,0o640);
  assert.equal(createHash('sha256').update(fs.readFileSync(privateFile)).digest('hex'),createHash('sha256').update(fs.readFileSync(deployed)).digest('hex'));
  assert.equal(fs.statSync(privateFile).mode&0o777,0o600);
  const current=ids(role);assert.equal(current.length,['runtime','toolhub','worker'].includes(role)?2:1);
  for(const id of current){const c=info(id);assert.equal(c.Image,s.image);assert.equal(c.Config.User,s.user);assert.equal(c.State.Health.Status,'healthy');}
  health(role);
 }
 await until(async()=>{
  const current=(await request('/status')).instances.filter(x=>x.active);
  return Object.keys(ports).every(role=>ids(role).every(id=>current.some(x=>x.role===role&&x.hostname===info(id).Config.Hostname)));
 },'each live role and replica has its own heartbeat');
 passed('Twelve exact owners with per-role replica heartbeats, matching private config bytes and actual health executables');
 phase='database authorization';
 const postgres=ids('postgres')[0];
 for(const role of Object.keys(ports)){
  const cfg=config(role),domain=ownerOf(role);
  if(!domain){assert(!cfg.DATABASE_URL);continue;}
  const url=new URL(cfg.DATABASE_URL),password=decodeURIComponent(url.password),user=decodeURIComponent(url.username);
  for(const candidate of domains){
   let output,error;
   try{output=run('docker',['exec','-i','--env','PGPASSWORD',postgres,'psql','-X','-h','127.0.0.1','-U',user,'-d','agentos_owner_ci_'+candidate,'-At','-v','ON_ERROR_STOP=1','-c','SELECT current_user,current_database()'],{env:{...process.env,PGPASSWORD:password}})}catch(e){error=e;}
   if(candidate===domain){assert(!error,'Own database login failed');assert.equal(output,user+'|agentos_owner_ci_'+domain);}
   else{assert(error&&/permission denied for database/.test(String(error.stderr)),'Expected actual cross-domain CONNECT refusal');}
  }
 }
 assert.equal(sql("SELECT to_regclass('public.artifacts') IS NULL AND to_regclass('public.secrets') IS NULL"),'t');
 assert.equal(sql("SELECT to_regclass('public.runs') IS NULL AND to_regclass('public.documents') IS NULL",'storage'),'t');
 assert.equal(internalRequest('registry','/v1/credentials/resolve',config('futures').SERVICE_TOKEN,{name:'SOURCES_MCP_TOKEN'}).status,403);
 passed('Ten real application logins, seventy explicit cross-domain CONNECT refusals and BFF credential denial');
 phase='knowledge and ToolHub';
 await request('/resources',{kind:'knowledge',id:'ci-kb',spec:{name:'CI lexical source',engine:'local',chunk_size:400}});
 const file=await request('/knowledge/upload',{knowledge:{id:'ci-kb',revision:1},name:'fixture.txt',source:'fixture://source',content:Buffer.from('甲醇库存是验收夹具。This is controlled evidence, not market information.').toString('base64')});
 assert.equal((await request('/knowledge/query',{knowledge:{id:'ci-kb',revision:1},query:'甲醇库存'})).hits[0].document_id,file.document_id);
 await request('/resources',{kind:'knowledge',id:'ci-kb',spec:{name:'CI isolated version',engine:'local',chunk_size:400}});
 assert.equal((await request('/knowledge/query',{knowledge:{id:'ci-kb',revision:2},query:'甲醇库存'})).hits.length,0);
 await request('/toolhub/assets',{kind:'skill',id:'ci-evidence',spec:{name:'CI evidence',content:'Preserve source references.'}});
 const skill='/toolhub/assets/skill/ci-evidence/1';
 await until(async()=>(await request(skill)).health==='healthy','Skill validation');
 await request(skill+'/activation',{enabled:true,reason:'CI controlled fixture review'});
 await request('/toolhub/assets',{kind:'connector',id:'blocked',spec:{endpoint:'https://169.254.169.254/latest',protocol:'2025-11-25',tools:[{name:'read',inputSchema:{type:'object'}}]}},{expect:422});
 const tools=await request('/connectors/discover',{endpoint:'http://fixture:8111/mcp',protocol:'2025-11-25'});
 await request('/toolhub/assets',{kind:'connector',id:'fixture',spec:{endpoint:'http://fixture:8111/mcp',protocol:'2025-11-25',read_only:true,tools}});
 const connector='/toolhub/assets/connector/fixture/1';
 await until(async()=>(await request(connector)).health==='healthy','MCP validation');
 await request(connector+'/activation',{enabled:true,reason:'CI read-only MCP fixture'});
 passed('Knowledge revision isolation, Skill checks, MCP handshake, activation and metadata-address refusal');
 phase='submit DSH task';
 const agent=await request('/resources',{kind:'agent',id:'ci-agent',spec:{name:'CI Agent',prompt:'Run fixture tools then finish.',tools:['note_save','document_read'],skills:[{id:'ci-evidence',revision:1}],connectors:[{id:'fixture',revision:1}],knowledge:[{id:'ci-kb',revision:1}],model:{base_url:'http://fixture:8111/v1',model:'fixture',key_env:''},publication:{enabled:true,app:'futures',name:'CI workflow'},max_steps:12}});
 const input={agent:{id:agent.id,revision:agent.revision},commodity:'CI fixture',period:'fixture only',question:'Verify independent owners'};
 const task=await request('/tasks',input,{business:true,key:'ci-owner-durable-task'});assert.match(task.id,/^[a-f0-9]{32}$/);
 assert.equal((await request('/tasks',input,{business:true,key:'ci-owner-durable-task'})).id,task.id);
 await request('/tasks',{...input,period:'changed'},{business:true,key:'ci-owner-durable-task',expect:400});
 await until(()=>sql("SELECT count(*) FROM calls WHERE run_id='"+task.id+"' AND request->>'name'='note_save' AND status='completed'")==='1','durable receipt before worker crash');
 const hostname=sql("SELECT hostname FROM instances WHERE id=(SELECT owner FROM runs WHERE id='"+task.id+"')");
 const victim=ids('worker').find(id=>info(id).Config.Hostname===hostname);assert(victim);
 const before=crash('worker',victim);
 await until(()=>info(victim).RestartCount>before,'Worker supervisor restart');
 await until(async()=>{const r=await request('/tasks/'+task.id,undefined,{business:true});assert(!['failed','needs_review'].includes(r.status),'Task could not recover');return r.status==='completed';},'DSH recovery with completed receipt',150);
 assert.match((await request('/tasks/'+task.id,undefined,{business:true})).result,/Controlled/);
 assert.equal(sql("SELECT count(*) FROM documents WHERE title='CI durable receipt'"),'1');
 assert(Number(sql("SELECT fence FROM runs WHERE id='"+task.id+"'"))>=2);
 assert.equal(sql("SELECT count(*) FROM calls WHERE run_id='"+task.id+"' AND kind='tool' AND status='completed'"),'4');
 passed('Actual Worker SIGKILL, higher fence, DSH replay and exactly one committed note plus four tool receipts');
 phase='degraded downstream services';
 const retained=(await request('/documents?q=CI%20durable%20receipt'))[0];assert(retained?.id);
 dc('stop','storage');
 try{assert.equal((await request('/documents/'+retained.id)).id,retained.id);const note=await request('/documents',{kind:'memory',title:'Runtime-owned note',content:'Independent Storage outage fixture.',source:'fixture://runtime',scope:'ci-agent'});assert.equal((await request('/documents/'+note.id)).scope,'ci-agent');}finally{dc('start','storage')}
 dc('stop','toolhub');
 try{const partial=await request('/resources');assert.equal(partial.services.toolhub,false);assert.equal(partial.services.registry,true);assert(partial.items.some(x=>x.id==='ci-agent'));assert.equal((await request('/tasks',undefined,{business:true})).length,1);}finally{dc('start','toolhub')}
 passed('Storage outage leaves Runtime notes readable/writable; ToolHub outage leaves Registry and business history usable');
 for(const role of Object.keys(ports).filter(x=>x!=='worker')){
  phase='independent crash '+role;const own=ids(role),other=snapshot(own),id=own[0],before=crash(role,id);
  await until(()=>{const c=info(id);return c.RestartCount>before&&c.State.Health?.Status==='healthy';},role+' supervisor recovery');
  assert.deepEqual(snapshot(own),other,'Other deployment processes changed');
 }
 passed('All remaining owner services restart after real application kill; non-target containers and restart counters unchanged');
 await until(()=>Number(sql('SELECT count(*) FROM telemetry_inbox WHERE exported_at IS NOT NULL','telemetry'))>0,'Telemetry actual fixture export');
 const received=internalRequest('fixture','/telemetry-receipts','fixture-only');assert.equal(received.status,200);assert(received.body.accepted_unique_spans>0&&received.body.accepted_trace_ids.includes(task.id),'OTLP receiver has no accepted spans for this task');
 const telemetry=internalRequest('telemetry','/readyz',config('telemetry').SERVICE_TOKEN);assert.equal(telemetry.status,200);
 passed('Independent Telemetry inbox exports actual task events to the controlled OTLP fixture');
 phase='database outage';
 const probes=['registry','runtime','knowledge'];for(const role of probes)health(role);
 dc('stop','postgres');await sleep(1500);
 try{for(const role of probes){let status=0;try{health(role)}catch(e){status=e.status}assert.equal(status,1,'Actual health executable must report database failure, not command missing');}}finally{dc('start','postgres')}
 await until(()=>{try{for(const role of probes)health(role);return true;}catch{return false;}},'all database health probes recover');
 assert.equal((await request('/knowledge/query',{knowledge:{id:'ci-kb',revision:1},query:'甲醇库存'})).hits.length,1);
 passed('Same health executables pass, fail with exit 1 during DB outage, then pass with retained knowledge');
 report.passed=true;
}catch{
 report.failed_phase=phase;console.error('Independent owner service check failed at '+phase+'; credentials and raw command arguments withheld.');process.exitCode=1;
}finally{
 fs.mkdirSync('.state/ci-owner-evidence',{recursive:true,mode:0o700});fs.writeFileSync('.state/ci-owner-evidence/service-smoke.json',JSON.stringify(report,null,2));
}
