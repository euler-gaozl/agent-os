import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {gzipSync} from 'node:zlib';
import {exportResearchPack} from './export-research-pack.mjs';
import {planArchiveImport,attachArchivePlan} from './attach-research-archives.mjs';
const hash=b=>createHash('sha256').update(b).digest('hex');
async function fixture() {
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'archive-import-'));
  const raw=Buffer.from('<p>证据🙂库存120</p>'), text=Buffer.from('前言🙂\n证据🙂库存120\n结束');
  await fs.writeFile(path.join(root,'raw.gz'),gzipSync(raw));await fs.writeFile(path.join(root,'text.txt'),text);
  const source={id:'fixture',title:'Controlled archive fixture',url:'https://example.com/archive',published_at:'2026-01-01',captured_at:'2026-01-02T00:00:00Z',scope:'fixture',quality_note:'not market data',raw_path:path.join(root,'raw.gz'),raw_sha256:hash(raw),text_path:path.join(root,'text.txt'),text_sha256:hash(text),excerpts:['证据🙂库存120']};
  const pack=path.join(root,'pack');const manifest=await exportResearchPack({format:1,sources:[source]},pack);
  const knowledge={id:'fixture',revision:1};
  return {root,pack,manifest,knowledge};
}
test('preflight preserves compressed bytes and converts UTF-16 to Unicode offsets',async()=>{
  const f=await fixture(),plan=await planArchiveImport(f.pack,f.knowledge),item=plan.items[0];
  assert.deepEqual(item.raw,await fs.readFile(path.join(f.root,'raw.gz')));
  assert.equal(item.input.spans[0].start,4);
  assert.equal(Array.from(item.input.text).slice(item.input.spans[0].start,item.input.spans[0].end).join(''),'证据🙂库存120');
  const s=item.input.spans[0];assert.equal(Array.from(item.documentBytes.toString()).slice(s.document_start,s.document_end).join(''),'证据🙂库存120');
});
test('all selected inputs reject malformed paths, hashes and assertions before any network call',async t=>{
  const f=await fixture();
  for(const [name,mutate] of [
    ['traversal',x=>x.raw_path='../raw.gz'],['absolute',x=>x.raw_path=path.join(f.root,'raw.gz')],
    ['alternate stream',x=>x.text_path+=':stream'],['wrong hash',x=>x.raw_sha256='0'.repeat(64)],
    ['wrong quote',x=>x.excerpts[0].text='false quote'],['offset',x=>x.excerpts[0].start_utf16++],
    ['invalid URL',x=>x.url='http://example.com'],['credential query',x=>x.url='https://example.com/?api_key=x%ZZ'],
    ['future',x=>x.captured_at='9999-01-01T00:00:00Z'],['impossible day',x=>x.captured_at='2026-02-30T00:00:00Z'],
    ['non RFC3339',x=>x.captured_at='January 2 2026'],['normalized URL',x=>x.url='https://EXAMPLE.com/archive']
  ]) await t.test(name,async()=>{
    const m=structuredClone(f.manifest);mutate(m.sources[0]);await fs.writeFile(path.join(f.pack,'manifest.json'),JSON.stringify(m));
    await assert.rejects(planArchiveImport(f.pack,f.knowledge));
  });
});
function fixtureApi(plan) {
  const file={id:'a'.repeat(32),document_id:'b'.repeat(32),kb_id:plan.knowledge.id,kb_revision:plan.knowledge.revision,artifact_hash:plan.items[0].input.file_sha256};
  const state={posts:0,archives:new Map(),dropNext:false,corrupt:false,wrongFile:false,mutate:null};
  const api=async(method,url,input,binary)=>{
    if(url.startsWith('/knowledge/files?')) return state.wrongFile?[]:[file];
    if(url.startsWith('/knowledge/artifacts/')) return plan.items[0].documentBytes;
    if(method==='POST') {
      state.posts++;
      const archive={format:1,file_id:file.id,document_id:file.document_id,knowledge:plan.knowledge,file_sha256:file.artifact_hash,url:input.url,captured_at:'2026-01-02T00:00:00Z',media_type:'text/html',extraction_method:input.extraction_method,raw_sha256:input.raw_sha256,raw_encoding:'gzip',stored_raw_sha256:hash(plan.items[0].raw),stored_raw_bytes:plan.items[0].raw.length,raw_bytes:plan.items[0].rawBytes,text_sha256:input.text_sha256,text_bytes:Buffer.byteLength(input.text),spans:structuredClone(input.spans),provenance:'operator_imported_archive: URL, capture time and extraction method are submitter assertions; hashes and matching spans verify retention consistency, not raw-to-text derivation, completeness or factual accuracy'};
      state.mutate?.(archive);
      const bytes=Buffer.from(JSON.stringify(archive)),h=hash(bytes);state.archives.set(h,{bytes,archive});
      if(state.dropNext){state.dropNext=false;throw Error('fixture reply lost after commit');}
      return {manifest_sha256:h,archive};
    }
    assert.equal(binary,true);const parts=url.split('/'),member=parts.pop(),h=parts.pop();const saved=state.archives.get(h);assert.ok(saved);
    if(member==='manifest') return saved.bytes;
    if(state.corrupt) return Buffer.from('corrupt');
    return member==='raw'?plan.items[0].raw:plan.items[0].textBytes;
  };
  return {api,state};
}
test('target preflight, lost-reply retry and member readback preserve deterministic receipt',async()=>{
  const f=await fixture(),plan=await planArchiveImport(f.pack,f.knowledge),{api,state}=fixtureApi(plan);
  state.wrongFile=true;await assert.rejects(attachArchivePlan(plan,api));assert.equal(state.posts,0);
  state.wrongFile=false;state.dropNext=true;await assert.rejects(attachArchivePlan(plan,api));assert.equal(state.archives.size,1);
  const receipts=await attachArchivePlan(plan,api);assert.equal(receipts.length,1);assert.equal(state.archives.size,1);assert.equal(receipts[0].all_members_readback,true);
  state.corrupt=true;await assert.rejects(attachArchivePlan(plan,api),/readback differs/);
});
test('self-consistent but incorrectly attributed server manifests fail import verification',async t=>{
  const f=await fixture(),plan=await planArchiveImport(f.pack,f.knowledge);
  for(const [name,mutate] of [['URL',x=>x.url='https://example.com/wrong'],['offset',x=>x.spans[0].start++],['encoding',x=>x.raw_encoding='identity'],['hash',x=>x.raw_sha256='0'.repeat(64)],['time',x=>x.captured_at='2026-01-03T00:00:00Z']]) await t.test(name,async()=>{
    const {api,state}=fixtureApi(plan);state.mutate=mutate;
    await assert.rejects(attachArchivePlan(plan,api),/differs from selected archive/);
  });
});
