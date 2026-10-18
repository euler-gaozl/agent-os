import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {gzipSync,gunzipSync} from 'node:zlib';
import {exportResearchPack} from './export-research-pack.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
test('archive export preserves originals and rejects invalid selections before writing', async t => {
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'research-pack-'));
  const raw=Buffer.from('<p>库存是100，随后修订为101。</p>');
  const body=Buffer.from('导航中也有库存\r\n库存是100\r\n库存是100，随后修订为101。\r\n');
  const compressed=gzipSync(raw);
  await fs.writeFile(path.join(root,'original.gz'),compressed);
  await fs.writeFile(path.join(root,'extracted.txt'),body);
  const source={id:'source-1',title:'Controlled archive fixture, not market data',url:'https://example.com/report',
    published_at:'2026-01-01',captured_at:'2026-01-02T00:00:00Z',scope:'test fixture',quality_note:'test only',
    raw_path:path.join(root,'original.gz'),raw_sha256:hash(raw),text_path:path.join(root,'extracted.txt'),text_sha256:hash(body),
    excerpts:[{text:'库存是100',start_line:3}],document_name:'归档选段.md'};
  const input={format:1,sources:[source]};
  const output=path.join(root,'accepted');
  const manifest=await exportResearchPack(input,output);
  assert.equal(manifest.sources[0].excerpts[0].start_line,3);
  assert.deepEqual(gunzipSync(await fs.readFile(path.join(output,manifest.sources[0].raw_path))),raw);
  assert.deepEqual(await fs.readFile(path.join(output,manifest.sources[0].text_path)),body);
  assert.equal(hash(await fs.readFile(path.join(output,manifest.sources[0].document_path))),manifest.sources[0].document_sha256);
  assert.equal('raw_path' in manifest.sources[0],true);
  assert.ok(!JSON.stringify(manifest).includes(root));
  await assert.rejects(exportResearchPack(input,output),{code:'EEXIST'});
  for (const [name,mutate] of [
    ['raw-corruption',x=>x.sources[0].raw_sha256='0'.repeat(64)],
    ['text-corruption',x=>x.sources[0].text_sha256='0'.repeat(64)],
    ['fabricated-quote',x=>x.sources[0].excerpts[0].text='fabricated'],
    ['wrong-line',x=>x.sources[0].excerpts[0].start_line=1],
    ['ambiguous-quote',x=>x.sources[0].excerpts=['库存是100']],
    ['duplicate-source',x=>x.sources.push(structuredClone(x.sources[0]))],
    ['escaping-name',x=>x.sources[0].document_name='../escape.md'],
    ['duplicate-name',x=>x.sources.push({...x.sources[0],id:'source-2'})],
  ]) {
    await t.test(name,async()=>{
      const changed=structuredClone(input);mutate(changed);
      const rejected=path.join(root,name);
      await assert.rejects(exportResearchPack(changed,rejected));
      await assert.rejects(fs.stat(rejected),{code:'ENOENT'});
    });
  }
  // The bounded fixture is retained in the caller's configured temp directory.
});
