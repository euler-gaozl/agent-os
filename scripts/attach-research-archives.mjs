// Explicit local archive import. Never fetches a source URL or sends model requests.
import fs from 'node:fs/promises';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {gunzipSync} from 'node:zlib';
import {pathToFileURL} from 'node:url';
import {isDeepStrictEqual} from 'node:util';
import {readLocalConfig,getLocalLayout} from './lib/local-layout.mjs';

const hash=b=>createHash('sha256').update(b).digest('hex');
const limit=1024*1024;
const digest=/^[a-f0-9]{64}$/;
const id=/^[a-f0-9]{32}$/;
const decode=b=>new TextDecoder('utf-8',{fatal:true,ignoreBOM:true}).decode(b);
const runes=s=>Array.from(s).length;
function canonicalTime(value) {
  const m=typeof value==='string'&&value.match(/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$/);
  if(!m) throw Error('RFC3339 capture time required');
  const parts=m[3]==='Z'?null:m[3].slice(1).split(':').map(Number);
  if(parts&&(parts[0]>23||parts[1]>59)) throw Error('Invalid capture offset');
  const offset=parts?(parts[0]*60+parts[1])*60000*(m[3][0]==='-'?-1:1):0;
  const when=Date.parse(m[1]+m[3]);
  if(!Number.isFinite(when)||new Date(when+offset).toISOString().slice(0,19)!==m[1]||when>Date.now()+300000) throw Error('Invalid historical capture time');
  const fraction=(m[2]||'').replace(/0+$/,'');
  return new Date(when).toISOString().slice(0,19)+(fraction?'.'+fraction:'')+'Z';
}
function within(root,file) {
  const rel=path.relative(root,file);
  return rel && rel!=='..' && !rel.startsWith('..'+path.sep) && !path.isAbsolute(rel);
}
async function readMember(root,relative,max=limit) {
  if(typeof relative!=='string'||!relative||path.isAbsolute(relative)||relative.includes('\\')||relative.split('/').some(x=>!x||x==='.'||x==='..'||x.includes(':'))) throw Error('Unsafe pack path');
  const file=path.resolve(root,relative);
  if(!within(root,file)) throw Error('Pack path escapes root');
  let current=root;
  for(const segment of relative.split('/')) {
    current=path.join(current,segment);
    if((await fs.lstat(current)).isSymbolicLink()) throw Error('Pack links are forbidden');
  }
  if(!within(root,await fs.realpath(file))) throw Error('Resolved pack member escapes root');
  const handle=await fs.open(file,'r');
  try {
    const stat=await handle.stat();
    if(!stat.isFile()||stat.size<1||stat.size>max) throw Error('Pack member size/type invalid');
    const bytes=await handle.readFile();
    if(bytes.length!==stat.size||bytes.length>max) throw Error('Pack member changed during read');
    return bytes;
  } finally {await handle.close();}
}
export async function planArchiveImport(packDirectory,knowledge) {
  if(!/^[a-zA-Z0-9_-]{1,128}$/.test(knowledge.id)||!Number.isSafeInteger(knowledge.revision)||knowledge.revision<1) throw Error('Exact knowledge revision required');
  const root=await fs.realpath(packDirectory);
  const manifestBytes=await readMember(root,'manifest.json');
  const manifest=JSON.parse(decode(manifestBytes));
  if(manifest.format!==1||!Array.isArray(manifest.sources)||!manifest.sources.length||manifest.sources.length>100) throw Error('Invalid source pack');
  const items=[],seen=new Set();
  for(const source of manifest.sources) {
    if(!/^[a-zA-Z0-9_-]{1,80}$/.test(source.id)||seen.has(source.id)) throw Error('Invalid/duplicate source ID');
    seen.add(source.id);
    const raw=await readMember(root,source.raw_path), textBytes=await readMember(root,source.text_path), documentBytes=await readMember(root,source.document_path);
    const expanded=gunzipSync(raw,{maxOutputLength:limit});
    if(![source.raw_sha256,source.text_sha256,source.document_sha256].every(x=>digest.test(x))||hash(expanded)!==source.raw_sha256||hash(textBytes)!==source.text_sha256||hash(documentBytes)!==source.document_sha256) throw Error('Archive hash mismatch');
    const text=decode(textBytes),document=decode(documentBytes);
    if(text.includes('\0')||document.includes('\0')) throw Error('NUL in source text');
    if(!Array.isArray(source.excerpts)||!source.excerpts.length||source.excerpts.length>64) throw Error('Exact excerpts required');
    const spans=source.excerpts.map(q=>{
      if(typeof q.text!=='string'||!q.text.trim()||!Number.isInteger(q.start_utf16)||!Number.isInteger(q.end_utf16)||q.start_utf16<0||q.end_utf16!==q.start_utf16+q.text.length||text.slice(q.start_utf16,q.end_utf16)!==q.text) throw Error('Archive quote mismatch');
      const start=document.indexOf(q.text);
      if(start<0||document.indexOf(q.text,start+1)!==-1) throw Error('Document quote absent or ambiguous');
      const span={start:runes(text.slice(0,q.start_utf16)),end:runes(text.slice(0,q.end_utf16)),document_start:runes(document.slice(0,start)),document_end:runes(document.slice(0,start+q.text.length))};
      if(Array.from(text).slice(span.start,span.end).join('')!==q.text||Array.from(document).slice(span.document_start,span.document_end).join('')!==q.text) throw Error('Quote splits a Unicode character');
      return span;
    });
    const capturedAt=canonicalTime(source.captured_at);
    const url=new URL(source.url);
    if(typeof source.url!=='string'||url.href!==source.url||url.protocol!=='https:'||url.username||url.password||url.hash||(url.port&&url.port!=='443')||source.url.length>2048) throw Error('Invalid source provenance');
    decodeURIComponent(url.search.replace(/\+/g,' '));
    if(url.search.includes(';')||Array.from(url.searchParams.keys()).some(k=>/token|api_key|apikey|password|secret|signature/i.test(k))) throw Error('Unsafe source query');
    if(source.media_type!==undefined && source.media_type!=='text/html') throw Error('This archive importer accepts HTML captures only');
    const input={file_sha256:source.document_sha256,url:source.url,captured_at:source.captured_at,media_type:source.media_type||'text/html',extraction_method:'Existing archive extraction retained without regeneration; imported from a selected research pack.',raw_sha256:source.raw_sha256,raw_encoding:'gzip',text_sha256:source.text_sha256,raw:raw.toString('base64'),text,spans};
    if(Buffer.byteLength(JSON.stringify(input))>2*limit) throw Error('Encoded request exceeds 2 MiB');
    items.push({source_id:source.id,input,raw,rawBytes:expanded.length,textBytes,documentBytes,capturedAt});
  }
  return {pack_sha256:hash(manifestBytes),knowledge,items};
}

function expectedArchive(item,knowledge) {
  const i=item.input;
  return {format:1,file_id:item.file.id,document_id:item.file.document_id,knowledge,file_sha256:i.file_sha256,url:i.url,captured_at:item.capturedAt,media_type:i.media_type,extraction_method:i.extraction_method,raw_sha256:i.raw_sha256,raw_encoding:i.raw_encoding,stored_raw_sha256:hash(item.raw),stored_raw_bytes:item.raw.length,raw_bytes:item.rawBytes,text_sha256:i.text_sha256,text_bytes:item.textBytes.length,spans:i.spans,provenance:'operator_imported_archive: URL, capture time and extraction method are submitter assertions; hashes and matching spans verify retention consistency, not raw-to-text derivation, completeness or factual accuracy'};
}

// All inputs and target uploads are verified before the first POST. The batch is
// deliberately not one transaction: per-file commits are retry-safe and receipts
// are reported immediately so an interrupted batch can be resumed by re-running.
export async function attachArchivePlan(plan,api,onProgress=async()=>{}) {
  const files=[],seen=new Set();let after='';
  for(let page=0;;page++) {
    if(page>=100) throw Error('Knowledge file listing exceeds bounded import scope');
    const part=await api('GET','/knowledge/files?id='+encodeURIComponent(plan.knowledge.id)+'&revision='+plan.knowledge.revision+(after?'&after='+after:''));
    if(!Array.isArray(part)||part.length>100) throw Error('Invalid file page');
    for(const file of part) {
      if(!id.test(file.id)||!id.test(file.document_id)||seen.has(file.id)||file.kb_id!==plan.knowledge.id||file.kb_revision!==plan.knowledge.revision) throw Error('Invalid target file identity');
      seen.add(file.id);files.push(file);
    }
    if(part.length<100) break;
    after=part.at(-1).id;
  }
  const bound=[];
  for(const item of plan.items) {
    const matches=files.filter(f=>f.artifact_hash===item.input.file_sha256);
    if(matches.length!==1) throw Error('Expected exactly one existing upload for selected source');
    const file=matches[0];
    const original=await api('GET','/knowledge/artifacts/'+file.artifact_hash,null,true);
    if(!Buffer.from(original).equals(item.documentBytes)) throw Error('Retained upload differs from source pack');
    bound.push({...item,file});
  }
  const receipts=[];
  for(const item of bound) {
    const base='/knowledge/files/'+item.file.id+'/source-archives';
    const result=await api('POST',base,item.input);
    if(!digest.test(result.manifest_sha256)||!isDeepStrictEqual(result.archive,expectedArchive(item,plan.knowledge))) throw Error('Attachment receipt differs from selected archive');
    const memberBase=base+'/'+result.manifest_sha256+'/';
    const manifestBytes=await api('GET',memberBase+'manifest',null,true);
    if(hash(manifestBytes)!==result.manifest_sha256||!isDeepStrictEqual(JSON.parse(decode(manifestBytes)),expectedArchive(item,plan.knowledge))) throw Error('Manifest readback differs');
    for(const [name,expected] of [['raw',item.raw],['text',item.textBytes]]) {
      if(!Buffer.from(await api('GET',memberBase+name,null,true)).equals(expected)) throw Error('Archive member readback differs');
    }
    const receipt={source_id:item.source_id,file_id:item.file.id,document_id:item.file.document_id,manifest_sha256:result.manifest_sha256,stored_raw_sha256:hash(item.raw),raw_sha256:item.input.raw_sha256,text_sha256:item.input.text_sha256,all_members_readback:true};
    receipts.push(receipt);await onProgress(receipt);
  }
  return receipts;
}

if(process.argv[1]&&import.meta.url===pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    const [pack,kb,revision,reportFile]=process.argv.slice(2);
    if(!pack||!kb||!revision||!reportFile||process.argv.length!==6) throw Error('Usage: node attach-research-archives.mjs <pack> <knowledge-id> <revision> <new-private-report.jsonl>');
    const layout=await getLocalLayout(),report=path.resolve(reportFile);
    if(!within(await fs.realpath(layout.evidence_root),await fs.realpath(path.dirname(report)))||!report.endsWith('.jsonl')) throw Error('Report must be inside a private evidence subdirectory');
    const plan=await planArchiveImport(pack,{id:kb,revision:Number(revision)});
    const c=await readLocalConfig('control');
    const api=async(method,endpoint,body,binary=false)=>{
      const response=await fetch('http://127.0.0.1:8090/api'+endpoint,{method,redirect:'error',signal:AbortSignal.timeout(20000),headers:{Authorization:'Bearer '+c.ADMIN_TOKEN,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});
      if(!response.ok) throw Error('Knowledge request failed: HTTP '+response.status);
      if(Number(response.headers.get('content-length'))>8*limit) throw Error('Knowledge response exceeds limit');
      const parts=[];let size=0;
      for await(const part of response.body) {size+=part.length;if(size>8*limit) throw Error('Knowledge response exceeds limit');parts.push(part);}
      const bytes=Buffer.concat(parts);
      return binary?bytes:JSON.parse(decode(bytes));
    };
    const output=await fs.open(report,'wx');
    try {
      await output.writeFile(JSON.stringify({format:1,pack_sha256:plan.pack_sha256,knowledge:plan.knowledge,status:'started'})+'\n');
      const receipts=await attachArchivePlan(plan,api,async receipt=>{await output.writeFile(JSON.stringify(receipt)+'\n');await output.sync();});
      await output.writeFile(JSON.stringify({status:'passed',attachments:receipts.length,model_calls:0})+'\n');
      console.log(JSON.stringify({status:'passed',attachments:receipts.length,model_calls:0,report}));
    } finally {await output.close();}
  } catch(error) {console.error(error.message);process.exitCode=1;}
}
