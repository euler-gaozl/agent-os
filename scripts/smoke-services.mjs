// Only run against the disposable CI Compose project. Never targets local user data.
import {execFileSync} from 'node:child_process';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const dc=(...args)=>execFileSync('docker',['compose','-f','compose.yaml','-f','deploy/compose.ci.yaml',...args],{encoding:'utf8',timeout:120000,stdio:['pipe','pipe','pipe']}).trim();
const docker=(...args)=>execFileSync('docker',args,{encoding:'utf8',timeout:30000,stdio:['pipe','pipe','pipe']}).trim();
// Crash the application process. `docker kill` is an operator stop and can
// suppress restart policy, so it is not a valid supervisor recovery test.
const crash=id=>docker('exec','--user','10001',id,'sh','-c','kill -KILL "$(pidof service)"');
const sql=q=>dc('exec','-T','postgres','psql','-U','agentos','-d','agentos','-At','-v','ON_ERROR_STOP=1','-c',q);
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const until=async(fn,label,seconds=90)=>{const end=Date.now()+seconds*1000;while(Date.now()<end){try{const v=await fn();if(v)return v}catch{}await sleep(1000)}throw Error('Timeout: '+label)};
const config=role=>JSON.parse(dc('exec','-T',role,'cat','/run/service.json'));
const admin=config('control').ADMIN_TOKEN,business=config('futures').BUSINESS_TOKEN;
async function request(path,body,options={}){
 const response=await fetch((options.business?'http://127.0.0.1:8098':'http://127.0.0.1:8090')+'/api'+path,{method:body===undefined?'GET':'POST',headers:{Authorization:'Bearer '+(options.business?business:admin),'Content-Type':'application/json',...(options.key?{'Idempotency-Key':options.key}:{})},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(12000)});
 const result=await response.json();if(options.expect){assert.equal(response.status,options.expect);return result}if(!response.ok)throw Error(path+': '+response.status+' '+JSON.stringify(result));return result;
}
const evidence={platform:'Linux Docker Compose',model:'controlled fixture, no real provider',checks:[],resources:[]};
function passed(name){evidence.checks.push(name);console.log('PASS '+name)}
let sampler=setInterval(()=>{try{const raw=docker('stats','--no-stream','--format','{{json .}}');const at=new Date().toISOString();evidence.resources.push(...raw.split('\n').filter(Boolean).map(x=>({time:at,...JSON.parse(x)})))}catch{}},4000);
try{
 await until(async()=>{const s=await request('/status');return s.instances.filter(x=>x.active).length>=12},'service heartbeats');
 for(const role of ['toolhub','knowledge','storage','sandbox','worker','sources']){
  let denied=false;try{sql('SET ROLE agentos_'+role+'; SELECT sealed FROM public.secrets LIMIT 1')}catch{denied=true}assert(denied,role+' database privilege');
 }
 assert(!config('control').DATABASE_URL && !config('futures').DATABASE_URL);passed('separate database identities and SQL denial; UI has no database credentials');
 const futures=config('futures');
 // Test authorization through a real internal HTTP request in the business container.
 const unauthorized=docker('exec',dc('ps','-q','futures'),'wget','-S','-O','/dev/null','--header=Authorization: Bearer '+futures.SERVICE_TOKEN,'--post-data={"name":"DEEPSEEK_API_KEY"}','http://registry:8096/v1/credentials/resolve');
 assert.fail('business credential access unexpectedly accepted '+unauthorized);
}catch(e){
 // wget deliberately exits nonzero for the required 403; other failures are not accepted.
 if(e.stderr?.toString().includes('403 Forbidden'))passed('business identity cannot resolve platform credentials');else{clearInterval(sampler);throw Error('service isolation or authorization check failed; command arguments redacted')}
}
try{
 await request('/resources',{kind:'knowledge',id:'ci-kb',spec:{name:'CI lexical source',engine:'local',chunk_size:400}});
 const file=await request('/knowledge/upload',{knowledge:{id:'ci-kb',revision:1},name:'fixture.txt',source:'fixture://source',content:Buffer.from('甲醇库存是验收夹具。This is controlled evidence, not market information.').toString('base64')});
 let found=await request('/knowledge/query',{knowledge:{id:'ci-kb',revision:1},query:'甲醇库存'});assert.equal(found.hits[0].document_id,file.document_id);
 await request('/resources',{kind:'knowledge',id:'ci-kb',spec:{name:'CI isolated version',engine:'local',chunk_size:400}});
 found=await request('/knowledge/query',{knowledge:{id:'ci-kb',revision:2},query:'甲醇库存'});assert.equal(found.hits.length,0);passed('indexed Chinese retrieval and exact knowledge version isolation');
 const asset=await request('/toolhub/assets',{kind:'skill',id:'ci-evidence',spec:{name:'CI evidence',content:'Preserve source references.'}});
 const assetPath='/toolhub/assets/skill/ci-evidence/1';
 await until(async()=> (await request(assetPath)).health==='healthy','skill check');
 await request(assetPath+'/activation',{enabled:true,reason:'CI controlled fixture review'});
 await request('/toolhub/assets',{kind:'connector',id:'blocked',spec:{endpoint:'https://169.254.169.254/latest',protocol:'2025-11-25',tools:[{name:'read',inputSchema:{type:'object'}}]}},{expect:422});
 const tools=await request('/connectors/discover',{endpoint:'http://fixture:8111/mcp',protocol:'2025-11-25'});
 await request('/toolhub/assets',{kind:'connector',id:'fixture',spec:{endpoint:'http://fixture:8111/mcp',protocol:'2025-11-25',read_only:true,tools}});
 await until(async()=> (await request('/toolhub/assets/connector/fixture/1')).health==='healthy','MCP check');
 await request('/toolhub/assets/connector/fixture/1/activation',{enabled:true,reason:'CI read-only MCP fixture'});passed('Skill checks, activation audit, MCP handshake and metadata address rejection');
 const agent=await request('/resources',{kind:'agent',id:'ci-agent',spec:{name:'CI Agent',prompt:'Run fixture tools then finish.',tools:['note_save','document_read'],skills:[{id:'ci-evidence',revision:1}],connectors:[{id:'fixture',revision:1}],knowledge:[{id:'ci-kb',revision:1}],model:{base_url:'http://fixture:8111/v1',model:'fixture',key_env:''},publication:{enabled:true,app:'futures',name:'CI workflow'},max_steps:12}});
 const input={agent:{id:agent.id,revision:agent.revision},commodity:'CI fixture',period:'fixture only',question:'Verify services'};
 const run=await request('/tasks',input,{business:true,key:'ci-durable-task'});
 const again=await request('/tasks',input,{business:true,key:'ci-durable-task'});assert.equal(run.id,again.id);
 await request('/tasks',{...input,period:'changed'},{business:true,key:'ci-durable-task',expect:400});
 await until(()=>sql("SELECT count(*) FROM calls WHERE run_id='"+run.id+"' AND request->>'name'='note_save' AND status='completed'")==='1','first durable tool receipt');
 const owner=sql("SELECT hostname FROM instances WHERE id=(SELECT owner FROM runs WHERE id='"+run.id+"')");assert(owner);
 const workers=dc('ps','-q','worker').split('\n');const victim=workers.find(id=>JSON.parse(docker('inspect',id))[0].Config.Hostname===owner);assert(victim,'owner container');
 crash(victim);
 const completed=await until(async()=>{const r=await request('/tasks/'+run.id,undefined,{business:true});if(r.status==='failed'||r.status==='needs_review')throw Error(JSON.stringify(r));return r.status==='completed'?r:null},'DSH task recovery',150);
 assert.match(completed.result,/Controlled/);
 assert.equal(sql("SELECT count(*) FROM documents WHERE title='CI durable receipt'"),'1');
 assert(Number(sql("SELECT fence FROM runs WHERE id='"+run.id+"'"))>=2);passed('real worker SIGKILL, fenced takeover, DSH replay and one committed note');
 assert.equal(sql("SELECT count(*) FROM calls WHERE run_id='"+run.id+"' AND kind='tool' AND status='completed'"),'4');passed('cross-service MCP call, KB search and bound original document read');
 dc('stop','toolhub');const partial=await request('/resources');assert.equal(partial.services.toolhub,false);assert.equal(partial.services.registry,true);assert(partial.items.some(x=>x.id==='ci-agent'));assert((await request('/tasks',undefined,{business:true})).length===1);dc('start','toolhub');passed('ToolHub outage leaves registry catalog and business history usable');
 for(const role of ['registry','runtime','knowledge','indexer','storage','control','futures','sources']){const ids=dc('ps','-q',role).split('\n');const before=JSON.parse(docker('inspect',ids[0]))[0].RestartCount;crash(ids[0]);await until(()=>{const state=JSON.parse(docker('inspect',ids[0]))[0];return state.RestartCount>before&&state.State.Health?.Status==='healthy'},role+' automatic restart',60)}
 assert((await request('/knowledge/query',{knowledge:{id:'ci-kb',revision:1},query:'甲醇库存'})).hits.length===1);passed('independent service crash restart retains data');
 dc('stop','postgres');await sleep(2000);
 for(const role of ['registry','runtime','knowledge']){let unhealthy=false;try{dc('exec','-T',role,'/app/healthcheck')}catch{unhealthy=true}assert(unhealthy,role+' must not report ready without DB')}
 dc('start','postgres');await until(async()=>{const r=await request('/knowledge/query',{knowledge:{id:'ci-kb',revision:1},query:'甲醇库存'});return r.hits.length===1},'database reconnect');passed('database outage marks services unready and connection pools recover');
}finally{clearInterval(sampler);fs.mkdirSync('.state/ci-evidence',{recursive:true});fs.writeFileSync('.state/ci-evidence/service-smoke.json',JSON.stringify(evidence,null,2))}
