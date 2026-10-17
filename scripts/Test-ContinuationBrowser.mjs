// Manual browser acceptance fixture for the real Console component and hooks.
// HTTP replies are synthetic: no Runtime database, worker or provider is used.
// C intentionally retains stale budget props: a fresh blocked context must
// still hide the action. A drops every POST reply until receipt lookup, since
// browsers may transparently retry a connection reset with the same request.
import { createServer } from 'node:http';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const consoleRoot = resolve(repo, '../agent-os-console');
const selected = JSON.parse(readFileSync(resolve(repo, 'deploy/service-sources.json'), 'utf8')).services.control;
const git = (...args) => execFileSync('git', ['-C', consoleRoot, ...args], { encoding: 'utf8' }).trim();
if (git('rev-parse', 'HEAD') !== selected.commit || git('status', '--porcelain')) throw Error('Console source differs from selected clean commit');
const root = resolve(process.argv[2] || '');
if (!root.toLowerCase().startsWith('d:\\workspace\\agent-platform\\local\\evidence\\')) throw Error('Use a local evidence directory');
mkdirSync(root, { recursive: true });
const require = createRequire(resolve(consoleRoot, 'web/package.json'));
const esbuild = createRequire(require.resolve('tsx'))('esbuild');
const entry = `
import React,{useState} from 'react';
import {createRoot} from 'react-dom/client';
import {ContinuationPanel} from './src/continuation';
import './src/design-tokens.css';import './src/foundation.css';import './src/continuation.css';
sessionStorage.setItem('admin-token','browser-fixture');
function App(){
 const [run,setRun]=useState('fixture-a'),[narrow,setNarrow]=useState(false),[state,setState]=useState('尚未查询');
 return <main style={{width:narrow?360:800,maxWidth:'100%',margin:'24px auto',padding:16,boxSizing:'border-box'}}>
  <h1>接续浏览器验收 · 合成 HTTP</h1><p>实际 Console 组件和 hooks；无数据库、无模型调用。</p>
  <nav><button onClick={()=>setRun('fixture-a')}>任务 A：丢回复</button> <button onClick={()=>setRun('fixture-b')}>任务 B：延迟回复</button> <button onClick={()=>setRun('fixture-c')}>任务 C：预算不足</button></nav>
  <button onClick={()=>setNarrow(!narrow)}>切换 360 像素容器</button>
  <h2>当前任务：{run}</h2>
  <ContinuationPanel key={run} run={run} status="failed" attempts={1} maxAttempts={4} refreshRun={async()=>{setState('刷新详情：'+run)}}/>
  <button onClick={async()=>setState(JSON.stringify(await (await fetch('/fixture/state')).json()))}>查询服务端计数</button><pre style={{whiteSpace:'pre-wrap',overflowWrap:'anywhere'}}>{state}</pre>
 </main>
}createRoot(document.getElementById('root')).render(<App/>);`;
const bundled = await esbuild.build({ stdin: { contents: entry, resolveDir: resolve(consoleRoot, 'web'), loader: 'tsx' }, bundle: true, write: false, outdir: 'dist', format: 'esm' });
const js = bundled.outputFiles.find(f => f.path.endsWith('.js')).contents;
const css = bundled.outputFiles.find(f => f.path.endsWith('.css')).contents;
const version = 'a'.repeat(64), records = new Map(), counts = {};
const journal = { source_commit: selected.commit, scope: 'Synthetic HTTP with actual React component; not Runtime or provider E2E', events: [] };
const record = event => { journal.events.push({ at: new Date().toISOString(), ...event }); writeFileSync(resolve(root, 'requests.json'), JSON.stringify(journal, null, 2)); };
const server = createServer(async (req, res) => {
 const send = (status, value) => { res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(value)); };
 try {
  if(req.url==='/'){res.writeHead(200,{'Content-Type':'text/html'});res.end('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>接续浏览器验收</title><link rel="stylesheet" href="/fixture.css"><div id="root"></div><script type="module" src="/fixture.js"></script>');return;}
  if(req.url==='/fixture.js'||req.url==='/fixture.css'){res.writeHead(200,{'Content-Type':req.url.endsWith('.js')?'text/javascript':'text/css'});res.end(req.url.endsWith('.js')?js:css);return;}
  if(req.url==='/fixture/state'){send(200,counts);return;}
  const match=req.url.match(/^\/api\/runs\/(fixture-[abc])\/continuation(?:\/(request-context|requests\/([A-Za-z0-9_-]+)))?$/);
  if(!match){send(404,{});return;}
  if(req.headers.authorization!=='Bearer browser-fixture'){send(401,{});return;}
  const run=match[1], stats=counts[run]??={posts:0,effects:0,lookups:0};
  if(req.method==='GET'&&match[2]==='request-context'){
   send(200,{protocol:'failed-run-continuation-action-context-v1',run_id:run,engine:'dsh-source-639ed015-native-v4',status:'failed',assessment:run==='fixture-c'?'blocked':'same_run_candidate',reason:run==='fixture-c'?'attempt_budget_exhausted':'retained_transient_model_failure',observed_at:new Date().toISOString(),failure_version:version});return;
  }
  if(req.method==='GET'&&match[3]){stats.lookups++;const receipt=records.get(run+':'+match[3]);record({kind:'lookup',run,request_id:match[3],found:!!receipt});send(receipt?200:404,receipt||{});return;}
  if(req.method!=='POST'||match[2]){send(405,{});return;}
  let body='';for await(const chunk of req){body+=chunk;if(body.length>4096){send(413,{});return;}}
  const request=JSON.parse(body);if(!/^[A-Za-z0-9_-]{1,128}$/.test(request.request_id)||request.expected_failure_version!==version||req.headers['idempotency-key']!==request.request_id){send(400,{});return;}
  stats.posts++;const key=run+':'+request.request_id;let receipt=records.get(key);
  if(!receipt){stats.effects++;receipt={protocol:'failed-run-continuation-receipt-v1',run_id:run,request_id:request.request_id,failure_version:version,committed:true,outcome:'queued',status_at_acceptance:'queued',accepted_at:new Date().toISOString()};records.set(key,receipt);}
  record({kind:'post_committed',run,request_id:request.request_id,posts:stats.posts,effects:stats.effects});
  if(run==='fixture-a'&&stats.lookups===0){record({kind:'reply_dropped',run});res.destroy();return;}
  if(run==='fixture-b')await new Promise(resolve=>setTimeout(resolve,4000));
  send(202,receipt);
 }catch{send(500,{error:'fixture request failed'});}
});
server.listen(18090,'127.0.0.1',()=>{record({kind:'started',port:18090});console.log('Browser fixture: http://127.0.0.1:18090/');});
for(const signal of ['SIGINT','SIGTERM'])process.on(signal,()=>server.close(()=>process.exit(0)));
