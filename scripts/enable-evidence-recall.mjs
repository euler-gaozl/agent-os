// Run only after the evidence-v1 rollout documented in independent-deployment.md.
// Updates the shipped personal Agents by creating immutable revisions. Model,
// credentials, bindings and publication settings are preserved. No model calls.
import {readLocalConfig} from './lib/local-layout.mjs';
import assert from 'node:assert/strict';
import {isDeepStrictEqual} from 'node:util';
const apply=process.argv.includes('--apply');
const config=await readLocalConfig('control');
async function api(route,body){const response=await fetch('http://127.0.0.1:8090/api'+route,{method:body===undefined?'GET':'POST',headers:{Authorization:'Bearer '+config.ADMIN_TOKEN,'Content-Type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(15000)});if(!response.ok)throw Error('Platform request failed: '+response.status);return response.json()}
const ids=new Set(['futures-research','general-assistant','published-supply-inventory','published-source-crosscheck','published-evidence-timeline']);
const rule='证据回查：摘要遗漏来源时，使用 run_recall 找回本任务及后代已提交的回执，再回读原文核验。has_more=false 只表示当前筛选下的回执页结束，不能证明资料覆盖完整或外部不存在其他证据。';
let after='';const resources=[];
do{const page=await api('/resources?after='+encodeURIComponent(after));if(Object.values(page.services).some(x=>!x))throw Error('Complete catalog required');resources.push(...page.items);after=page.next_cursor||'';}while(after);
const report=[];
for(const original of resources.filter(x=>x.kind==='agent'&&ids.has(x.id))){
 const spec={...original.spec,tools:[...new Set([...(original.spec.tools||[]),'run_recall'])],constraints:[...new Set([...(original.spec.constraints||[]),rule])]};
 if(isDeepStrictEqual(spec,original.spec))continue;
 if(!apply){report.push({id:original.id,from:original.revision,action:'would create revision'});continue}
 const updated=await api('/resources',{kind:'agent',id:original.id,spec});
 const old=await api(`/resources/agent/${encodeURIComponent(original.id)}/${original.revision}`);
 assert(isDeepStrictEqual(old.spec,original.spec),'Historical Agent revision changed');
 assert(isDeepStrictEqual(updated.spec,spec),'New Agent differs from proposed revision');
 report.push({id:original.id,from:original.revision,to:updated.revision,old_revision_preserved:true});
}
console.log(JSON.stringify({applied:apply,changed:report.length,agents:report}));
