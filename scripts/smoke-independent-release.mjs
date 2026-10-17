// Disposable Linux CI only. Replaces Knowledge with an older real binary,
// upgrades it, rolls it back, scales it and tests a rejected unhealthy release.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
const command=(program,args,timeout=150000)=>execFileSync(program,args,{encoding:'utf8',timeout,stdio:['pipe','pipe','pipe']}).trim();
const docker=(...args)=>command('docker',args);
const dc=(...args)=>docker('compose','-f','compose.yaml','-f','deploy/compose.ci.yaml',...args);
const config=JSON.parse(fs.readFileSync('.state/services/control.json','utf8'));
const project='agentos-ci-knowledge-release';
const evidence={baseline:'a0d6c81',checks:[],releases:[]};
const check=(name)=>{evidence.checks.push(name);console.log('PASS '+name)};
const hash=b=>createHash('sha256').update(b).digest('hex');
const configs=()=>Object.fromEntries(fs.readdirSync('.state/services').filter(x=>x.endsWith('.json')).sort().map(x=>[x,hash(fs.readFileSync('.state/services/'+x))]));
async function api(route,body){const r=await fetch('http://127.0.0.1:8090/api'+route,{method:body?'POST':'GET',headers:{Authorization:'Bearer '+config.ADMIN_TOKEN,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(12000)});assert(r.ok,'Console request failed: '+route);return r.json()}
const query=()=>api('/knowledge/query',{knowledge:{id:'ci-kb',revision:1},query:'甲醇库存'});
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function queryReady(){for(let i=0;i<30;i++){try{const r=await query();if(r.hits.length===1)return r}catch{}await sleep(500)}throw Error('retrieval did not recover')}
const allIDs=()=>dc('ps','-q').split('\n').filter(Boolean).sort();
const knowledgeID=dc('ps','-q','knowledge');
const unrelated=allIDs().filter(x=>x!==knowledgeID);
const knowledgeInfo=JSON.parse(docker('inspect',knowledgeID))[0];
const network=Object.keys(knowledgeInfo.NetworkSettings.Networks)[0];
function stable(){assert.deepEqual(allIDs(),unrelated);for(const c of JSON.parse(docker('inspect',...unrelated)))assert.equal(c.State.Status,'running')}
function release(image,replicas=1){const out=command(process.execPath,['scripts/release-service.mjs','deploy','--project',project,'--service','knowledge','--image',image,'--config',path.resolve('.state/services/knowledge.json'),'--network',network,'--replicas',String(replicas)]);evidence.releases.push(JSON.parse(out));stable()}
try{
 const before=configs();
 const original=await queryReady();
 dc('run','--rm','--no-deps','--entrypoint','/app/service','migrate','--service','knowledge');
 assert.deepEqual(configs(),before);assert.deepEqual(allIDs().sort(),[...unrelated,knowledgeID].sort());
 check('selected Knowledge migration leaves all configuration bytes and other containers unchanged');
 dc('stop','knowledge');dc('rm','-f','knowledge');
 release('agent-os-knowledge:baseline');
 assert.equal((await queryReady()).hits[0].document_id,original.hits[0].document_id);
 check('older independently deployed Knowledge reads current schema through existing Console');
 release('agent-os-knowledge:0.5.0');
 await queryReady();check('single-service upgrade preserves source and does not recreate other services');
 command(process.execPath,['scripts/release-service.mjs','rollback','--project',project]);
 stable();await queryReady();check('real previous-binary rollback remains compatible');
 release('agent-os-knowledge:0.5.0',2);
 const own=docker('ps','-q','--filter','label=com.docker.compose.project='+project).split('\n');
 assert.equal(own.length,2);await queryReady();check('Knowledge scales to two independent instances');
 // The Registry binary cannot authenticate as Knowledge and must fail to
 // become ready. The release controller must restore the healthy replica pair.
 let rejected=false;
 try{release('agent-os-registry:0.5.0',2)}catch{rejected=true}
 assert(rejected);stable();await queryReady();
 const saved=JSON.parse(fs.readFileSync('.state/deployments/'+project+'/release.json','utf8'));
 assert.equal(saved.current.replicas,2);
 assert(saved.history.some(x=>x.action==='failed'&&x.recovery==='previous release restored'));
 check('unhealthy release rejected and prior replicas automatically restored');
 command(process.execPath,['scripts/release-service.mjs','stop','--project',project]);
 assert((await api('/resources')).items.some(x=>x.id==='ci-agent'));stable();
 check('stopping independent Knowledge leaves Registry catalog available');
 assert.deepEqual(configs(),before);
}finally{
 fs.writeFileSync('.state/ci-evidence/independent-release.json',JSON.stringify(evidence,null,2));
 // Explicitly remove only this disposable CI deployment unit.
 try{const state=JSON.parse(fs.readFileSync('.state/deployments/'+project+'/release.json','utf8'));const ids=docker('ps','-aq','--filter','label=com.docker.compose.project='+project).split('\n').filter(Boolean);if(ids.length)docker('rm','-f',...ids)}catch{}
 dc('up','-d','--no-deps','--wait','knowledge');
}
