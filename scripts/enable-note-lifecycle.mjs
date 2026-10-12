// Run only after the note lifecycle rollout documented in independent-deployment.md.
// Updates the shipped personal Agents by creating immutable revisions. Model,
// credentials, bindings and publication settings are preserved. No model calls.
import {readLocalConfig} from './lib/local-layout.mjs';
import assert from 'node:assert/strict';
import {isDeepStrictEqual} from 'node:util';
const apply=process.argv.includes('--apply');
const config=await readLocalConfig('control');
async function api(route,body){const response=await fetch('http://127.0.0.1:8090/api'+route,{method:body===undefined?'GET':'POST',headers:{Authorization:'Bearer '+config.ADMIN_TOKEN,'Content-Type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(15000)});if(!response.ok)throw Error('Platform request failed: '+response.status);return response.json()}
const ids=new Set(['futures-research','general-assistant','published-supply-inventory','published-source-crosscheck','published-evidence-timeline']);
const rule='笔记生命周期：有来源更正时使用 note_revise 并保留修改理由；只有用户要求或明确失效、撤回依据时使用 note_retire，不因压缩上下文或临时任务结束而撤回有用资料。模型只能修改本 Agent 的记录，全局共享记录只读。knowledge_search 的有效视图包含全局共享和本 Agent 的记录；空结果不代表外部资料不存在。';
let after='';const resources=[];
do{const page=await api('/resources?after='+encodeURIComponent(after));if(Object.values(page.services).some(x=>!x))throw Error('Complete catalog required');resources.push(...page.items);after=page.next_cursor||'';}while(after);
const report=[];
for(const original of resources.filter(x=>x.kind==='agent'&&ids.has(x.id))){
 const spec={...original.spec,tools:[...new Set([...(original.spec.tools||[]),'note_revise','note_retire'])],constraints:[...new Set([...(original.spec.constraints||[]),rule])]};
 if(isDeepStrictEqual(spec,original.spec))continue;
 if(!apply){report.push({id:original.id,from:original.revision,action:'would create revision'});continue}
 const updated=await api('/resources',{kind:'agent',id:original.id,spec});
 const old=await api(`/resources/agent/${encodeURIComponent(original.id)}/${original.revision}`);
 assert(isDeepStrictEqual(old.spec,original.spec),'Historical Agent revision changed');
 assert(isDeepStrictEqual(updated.spec,spec),'New Agent differs from proposed revision');
 report.push({id:original.id,from:original.revision,to:updated.revision,old_revision_preserved:true});
}
console.log(JSON.stringify({applied:apply,changed:report.length,agents:report}));
