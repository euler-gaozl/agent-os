// Existing Owner image moved into its own managed deployment unit. This does
// not claim a different-version binary rollback or release-controller SIGKILL.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {ports} from './lib/owner-stack.mjs';
if(process.platform!=='linux'||process.env.GITHUB_ACTIONS!=='true'||process.env.RUNNER_ENVIRONMENT!=='github-hosted')throw Error('Disposable hosted Linux CI only');
const root=path.resolve('.state/owner-stack'),file=path.join(root,'compose.json');
const owners=JSON.parse(fs.readFileSync(path.join(root,'owners.json'),'utf8'));
const command=(program,args)=>execFileSync(program,args,{encoding:'utf8',timeout:180000,stdio:['pipe','pipe','pipe']}).trim();
const docker=(...args)=>command('docker',args),dc=(...args)=>docker('compose','-p','agentos-owner-ci','-f',file,...args);
const roleIDs=role=>dc('ps','-q',role).split('\n').filter(Boolean);
const units=project=>docker('ps','-q','--filter','label=com.docker.compose.project='+project).split('\n').filter(Boolean).sort();
const snapshot=exclude=>{const ids=dc('ps','-q').split('\n').filter(x=>x&&!exclude.includes(x));return JSON.parse(docker('inspect',...ids)).map(x=>({id:x.Id,start:x.State.StartedAt,restarts:x.RestartCount})).sort((a,b)=>a.id.localeCompare(b.id))};
const admin=JSON.parse(fs.readFileSync(path.join(root,'bootstrap/control.json'),'utf8')).ADMIN_TOKEN;
const business=JSON.parse(fs.readFileSync(path.join(root,'bootstrap/futures.json'),'utf8')).BUSINESS_TOKEN;
const report={passed:false,checks:[],provider_calls:0,scope:'Twelve independently managed Owner deployments, wrong-owner rejection and Knowledge replica-count rollback; not a different-version binary rollback or release-controller crash'};
let phase='start';
const hash=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const configs=()=>Object.fromEntries(Object.keys(ports).map(role=>[role,hash(path.join(root,'services',role+'.json'))]));
async function api(route,body,biz=false){const r=await fetch('http://127.0.0.1:'+(biz?8098:8090)+'/api'+route,{method:body===undefined?'GET':'POST',headers:{Authorization:'Bearer '+(biz?business:admin),'Content-Type':'application/json',...(biz&&body?{'Idempotency-Key':'owner-unit-worker-task'}:{})},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(12000)});assert(r.ok,'Gateway request failed');return r.json()}
async function query(){for(let i=0;i<30;i++){try{const q=await api('/knowledge/query',{knowledge:{id:'ci-kb',revision:1},query:'甲醇库存'});if(q.hits.length===1)return q.hits[0].document_id;}catch{}await new Promise(r=>setTimeout(r,500));}throw Error('Retained query unavailable')}
try{
 const original=await query(),configuration=configs();
 const network=Object.keys(JSON.parse(docker('inspect',roleIDs('registry')[0]))[0].NetworkSettings.Networks)[0];
 for(const role of Object.keys(ports)){
  phase=role+' unit deployment';const project='agentos-owner-unit-'+role,own=roleIDs(role),other=snapshot(own);assert(own.length>0);
  const args=['scripts/release-service.mjs','deploy','--project',project,'--service',role,'--image',owners[role].image,'--owner-report',path.resolve('.state/owner-reports','owner-image-'+role,'result.json'),'--config',path.join(root,'services',role+'.json'),'--network',network,'--replicas',String(own.length)];
  if(['control','futures'].includes(role))args.push('--publish',String(ports[role]));
  try{
   dc('stop',role);dc('rm','-f',role);
   command(process.execPath,args);assert.equal(units(project).length,own.length);assert.equal(await query(),original);
   assert.deepEqual(snapshot([]),other,'Independent release changed another owner process');
   assert.deepEqual(configs(),configuration,'Independent release changed configuration');
   const before=units(project),wrong=role==='registry'?'knowledge':'registry',bad=[...args];
   bad[bad.indexOf('--image')+1]=owners[wrong].image;
   bad[bad.indexOf('--owner-report')+1]=path.resolve('.state/owner-reports','owner-image-'+wrong,'result.json');
   let rejected=false;try{command(process.execPath,bad)}catch(e){rejected=/Owner report belongs to a different service/.test(String(e.stderr));}
   assert(rejected,'Wrong owner must fail before container replacement');assert.deepEqual(units(project),before);
   if(role==='knowledge'){
    phase='Knowledge independent scale and replica rollback';const scaled=[...args];scaled[scaled.indexOf('--replicas')+1]='2';
    command(process.execPath,scaled);assert.equal(units(project).length,2);assert.equal(await query(),original);
    command(process.execPath,['scripts/release-service.mjs','rollback','--project',project]);assert.equal(units(project).length,1);assert.equal(await query(),original);
    assert.deepEqual(snapshot([]),other);
   }
   if(role==='worker'){
    phase='independent Worker actually executes DSH task';
    const task=await api('/tasks',{agent:{id:'ci-agent',revision:1},commodity:'CI fixture',period:'Independent Worker unit',question:'Execute the controlled service workflow'},true);
    let completed=false;
    for(let i=0;i<100;i++){
     const r=await api('/tasks/'+task.id,undefined,true);assert(!['failed','needs_review'].includes(r.status));
     if(r.status==='completed'){assert.match(r.result,/Controlled/);completed=true;break;}await new Promise(r=>setTimeout(r,500));
    }
    assert(completed,'Independent Worker did not finish task');
    const calls=await api('/runs/'+task.id+'/calls');assert.equal(calls.filter(c=>c.kind==='tool'&&c.status==='completed').length,4);
   }
   const catalog=await api('/catalog');assert(catalog.services.registry&&catalog.services.toolhub);assert(catalog.items.some(x=>x.id==='ci-agent'));
   report.checks.push({role,commit:owners[role].commit,image:owners[role].image,independently_deployed:true,wrong_owner_rejected_before_replacement:true,other_owners_unchanged:true,retained_source_readable:true,...(role==='knowledge'?{scaled_to_two:true,replica_count_rollback:true}:{})});
   console.log('PASS independent deployment and wrong-owner refusal: '+role);
  }finally{
   // Only explicitly named disposable unit containers are removed, never user
   // installations. Restoration is mandatory; failures fail this CI scenario.
   try{
    const remaining=docker('ps','-aq','--filter','label=com.docker.compose.project='+project).split('\n').filter(Boolean);
    if(remaining.length)docker('rm','-f',...remaining);
   }finally{dc('up','-d','--no-deps','--wait','--wait-timeout','100',role);}
  }
 }
 report.passed=true;
}catch{
 report.failed_phase=phase;console.error('Independent owner release failed at '+phase+'; command details withheld.');process.exitCode=1;
}finally{fs.writeFileSync('.state/ci-owner-evidence/releases.json',JSON.stringify(report,null,2));}
