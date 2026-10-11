// Configure the reviewed first-party read-only MCP adapter through platform APIs.
// Credentials are references only; the source token remains encrypted in Registry.
import fs from 'node:fs/promises';
import {isDeepStrictEqual} from 'node:util';
const config=JSON.parse(await fs.readFile('.state/services/control.json','utf8'));
async function api(path,body){const r=await fetch('http://127.0.0.1:8090/api'+path,{method:body===undefined?'GET':'POST',headers:{Authorization:'Bearer '+config.ADMIN_TOKEN,'Content-Type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(15000)});if(!r.ok)throw Error(`Platform HTTP ${r.status} at ${path}`);return r.json()}
const endpoint='http://127.0.0.1:8101/mcp';
const tools=await api('/connectors/discover',{endpoint,protocol:'2025-11-25',key_env:'SOURCES_MCP_TOKEN'});
const spec={name:'公开资料采集与原文留存',endpoint,protocol:'2025-11-25',key_env:'SOURCES_MCP_TOKEN',read_only:true,tools};
const before=await api('/resources');
const previous=before.items.find(x=>x.kind==='connector'&&x.id==='public-sources');
const asset=previous&&isDeepStrictEqual(previous.spec,spec)?previous:await api('/toolhub/assets',{kind:'connector',id:'public-sources',spec});
const path='/toolhub/assets/connector/public-sources/'+asset.revision;
let checked;for(let i=0;i<20;i++){checked=await api(path);if(checked.health==='healthy')break;if(['rejected','drifted','unhealthy'].includes(checked.health))throw Error('Source adapter check did not pass');await new Promise(r=>setTimeout(r,1000))}
if(checked.health!=='healthy')throw Error('Source check timeout');
if(!checked.enabled)await api(path+'/activation',{enabled:true,reason:'First-party read-only public HTTPS acquisition adapter reviewed; exact host allowlist, bounded parsing and original-byte persistence validated.'});
const catalog=await api('/resources');let count=0;
for(const a of catalog.items.filter(x=>x.kind==='agent'&&(x.id==='futures-research'||x.spec.publication?.app==='futures'))){
 const connectors=(a.spec.connectors||[]).filter(x=>x.id!=='public-sources');connectors.push({id:'public-sources',revision:asset.revision});
 const instruction='\n\n外部资料：先调用公开资料 source_catalog，按核心问题获取目录或用户给定的原文 URL；fetch_page 留存原始响应，find_capture 定位相关正文或链接，read_capture 核对全文。注明 source URL、capture_id、raw_sha256 和统计时间。采集时间不等于发布日期。不要以行情涨跌或价格页面解释基本面。接口拒绝、未披露或尚未取得的数据必须如实标注；计划和实绩分开。';
 const prompt=a.spec.prompt.includes('外部资料：先调用公开资料')?a.spec.prompt:a.spec.prompt+instruction;
 const next={...a.spec,prompt,connectors,max_steps:18,max_model_attempts:40,model_token_budget:250000};
 if(!isDeepStrictEqual(next,a.spec)){await api('/resources',{kind:'agent',id:a.id,spec:next});count++;}
}
console.log(JSON.stringify({source_adapter_revision:asset.revision,futures_agents_updated:count}));
