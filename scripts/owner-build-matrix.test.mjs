import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {matrix} from './owner-build-matrix.mjs';
const locked=()=>JSON.parse(fs.readFileSync(new URL('../deploy/service-sources.json',import.meta.url),'utf8'));
test('only the twelve reviewed repositories and full immutable refs reach private checkout',()=>{
 const output=matrix(locked());assert.equal(output.include.length,12);
 assert.deepEqual(output.include.find(x=>x.role==='control'),{role:'control',repository:'agent-os-console',commit:locked().services.control.commit,secret:'AGENTOS_OWNER_READ_CONTROL'});
 for(const change of [l=>delete l.services.worker,l=>l.services.fake={},l=>l.services.runtime.commit='main',l=>l.services.control.repository='other/private',l=>l.services.runtime.repository='agent-os-runtime;false']){
  const input=locked();change(input);assert.throws(()=>matrix(input));
 }
});
