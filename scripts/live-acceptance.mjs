// Opt-in paid tests against the user's running LOCAL platform. No credentials
// are accepted on the command line, written to artifacts, or sent to GitHub CI.
import fs from 'node:fs/promises';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
if(!process.argv.includes('--allow-paid'))throw Error('Explicit --allow-paid required; official DeepSeek calls incur charges.');
const root=process.cwd();
const control=JSON.parse(await fs.readFile(root+'/.state/services/control.json','utf8'));
const worker=JSON.parse(await fs.readFile(root+'/.state/services/worker.json','utf8'));
const out=root+'/.state/live-e2e';await fs.mkdir(out,{recursive:true});
async function api(path,body,key){const r=await fetch('http://127.0.0.1:8090/api'+path,{method:body===undefined?'GET':'POST',headers:{Authorization:'Bearer '+control.ADMIN_TOKEN,'Content-Type':'application/json',...(key?{'Idempotency-Key':key}:{})},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(15000)});if(!r.ok)throw Error(`Platform HTTP ${r.status} at ${path}`);return r.json()}
async function balance(){
 const r=await fetch('http://127.0.0.1:8096/v1/credentials/resolve',{method:'POST',headers:{Authorization:'Bearer '+worker.SERVICE_TOKEN,'Content-Type':'application/json'},body:JSON.stringify({name:'DEEPSEEK_API_KEY'}),signal:AbortSignal.timeout(10000)});
 if(!r.ok)throw Error('Local credential resolution failed');
 let credential=await r.json();const b=await fetch('https://api.deepseek.com/user/balance',{redirect:'error',headers:{Authorization:'Bearer '+credential.value},signal:AbortSignal.timeout(15000)});credential=null;
 if(!b.ok)throw Error('Official balance request failed');const v=await b.json();const c=v.balance_infos?.find(x=>x.currency==='CNY');if(!c||!v.is_available)throw Error('Usable CNY balance required');return Number(c.total_balance);
}
const initial=await balance();const baseline=JSON.parse(await fs.readFile(out+'/baseline.json','utf8'));
const minimum=baseline.balance_cny-baseline.phase_budget_cny;
const report={started_at:new Date().toISOString(),provider:'https://api.deepseek.com',model:'deepseek-flash',balance_before:initial,checks:[]};
const base={name:'真实模型验收',prompt:'只根据工具回执回答。测试材料不是真实市场事实。不输出交易建议。不要重复已完成的工具调用。',model:{base_url:'https://api.deepseek.com',model:'deepseek-flash',key_env:'DEEPSEEK_API_KEY',thinking:'disabled',max_tokens:2048},tools:['document_read','note_save','artifact_read'],max_steps:8,max_model_attempts:16,model_token_budget:150000,context_tokens:32000,max_children:0};
async function agent(id,spec){return api('/resources',{kind:'agent',id,spec:{...base,...spec}})}
async function run(label,a,task,check){
 if(await balance()<minimum+0.5)throw Error('Paid acceptance budget nearly exhausted');
 const input={agent:{id:a.id,revision:a.revision},task};const key=randomUUID();const submitted=await api('/runs',input,key);assert.equal((await api('/runs',input,key)).id,submitted.id);
 let result;const end=Date.now()+180000;
 try{while(Date.now()<end){result=await api('/runs/'+submitted.id);if(['completed','failed','cancelled','waiting_unknown'].includes(result.status))break;await new Promise(r=>setTimeout(r,1500))}
 if(result?.status!=='completed')throw Error(`${label} ended with ${result?.status}: ${result?.state?.error||'timeout'}`);
 const calls=await api('/runs/'+submitted.id+'/calls');const usage=await api('/runs/'+submitted.id+'/usage');await check(result,calls,usage);
 await fs.writeFile(out+'/'+label+'.json',JSON.stringify({run:result,calls,usage},null,2));
 report.checks.push({label,run_id:submitted.id,status:'passed',usage});console.log('PASS '+label);
 }catch(e){await api('/runs/'+submitted.id+'/cancel',{}).catch(()=>{});report.checks.push({label,run_id:submitted.id,status:'failed'});throw e}
 finally{await fs.writeFile(out+'/live-summary.json',JSON.stringify(report,null,2))}
}
try{
 const resources=await api('/resources');const kb=resources.items.find(x=>x.kind==='knowledge'&&x.id==='delivery-acceptance');assert(kb,'Isolated acceptance knowledge base must exist');
 const knowledge=[{id:kb.id,revision:kb.revision}];
 const thinking=await agent('delivery-thinking',{model:{...base.model,thinking:'enabled',reasoning_effort:'low'},knowledge});
 await run('thinking-tools',thinking,'先 kb_search 查询“甲醇库存”，document_read 回读原文。回答原文中的校验编号和两次实绩变化，用一句话说明计划不是实绩。引用原文 ID，明确是验收样本。',(r,c)=>{assert.match(r.state.result,/AZ-731/);assert.match(r.state.result,/15/);assert(c.some(x=>x.kind==='tool'&&x.request.name==='document_read'));assert(c.some(x=>x.kind==='model'&&x.response.choices?.[0]?.message?.reasoning_content));});
 const child=await agent('delivery-child',{knowledge});
 const parent=await agent('delivery-parent',{tools:['spawn_agent'],child_agents:[{id:child.id,revision:child.revision}],max_children:1});
 await run('parent-child',parent,'必须调用 spawn_agent，把读取 delivery-acceptance 知识库中甲醇库存并核实校验编号的任务交给 delivery-child。等待真实子任务完成，然后简要报告编号与库存变化，明确是验收样本。',(r,c,u)=>{assert.match(r.state.result,/AZ-731/);assert(c.some(x=>x.request.name==='spawn_agent'));assert(u.attempts>=3);});
 const assets=await api('/resources');const skill=assets.items.find(x=>x.kind==='skill'&&x.id==='delivery-reference-check');const connector=assets.items.find(x=>x.kind==='connector'&&x.id==='deepwiki-public');assert(skill&&connector,'Reviewed live Skill and MCP required');
 const remote=await agent('delivery-mcp-skill',{tools:['artifact_read'],skills:[{id:skill.id,revision:skill.revision}],connectors:[{id:connector.id,revision:connector.revision}]});
 await run('real-mcp-skill',remote,'先阅读 Skill 的 references/check.txt。然后通过 MCP read_wiki_structure 读取公开仓库 golang/go 的文档目录。只列三个回执中确实存在的章节名和 Skill 校验标记，不调用 ask_wiki_question，不发送任何私有仓库信息。',(r,c)=>{assert.match(r.state.result,/SKILL-REF-284/);assert(c.some(x=>x.request.name==='skill_file_read'));const call=c.find(x=>x.request.name==='mcp_deepwiki-public_read_wiki_structure');assert(call?.status==='completed');assert(!call.response?.isError);});
}finally{report.finished_at=new Date().toISOString();report.balance_after=await balance().catch(()=>null);report.balance_delta=report.balance_after===null?null:report.balance_before-report.balance_after;await fs.writeFile(out+'/live-summary.json',JSON.stringify(report,null,2));console.log(JSON.stringify({checks:report.checks.map(x=>({label:x.label,status:x.status})),balance_before:report.balance_before,balance_after:report.balance_after}));}
