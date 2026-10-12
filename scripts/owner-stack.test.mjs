import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {verifyReports,composeFor,migrationArguments,ports,domains,ownerOf} from './lib/owner-stack.mjs';
const lock=JSON.parse(fs.readFileSync(new URL('../deploy/service-sources.json',import.meta.url),'utf8')),commit='a'.repeat(40);
function reports(){return Object.entries(lock.services).map(([role,e])=>{
 const app=['worker','control','futures'].includes(role),base=app?'/app':'/usr/local/bin';
 return {passed:true,integration_commit:commit,services:[{role,...e,image:'sha256:'+'1'.repeat(64),image_archive_sha256:'2'.repeat(64),executables_checked:true,uid:app?'10001':'65532',user:app?'10001':'65532:65532',entrypoint:base+'/service',healthcheck:base+'/healthcheck',migration_owner:ownerOf(role)??'none',migrator:domains.includes(role)?base+'/migrate':null,binary_checks:Array(domains.includes(role)?3:2).fill({})}]};
})}
test('composition requires exact owners and carries UID-specific paths, immutable images and isolated config',()=>{
 const selected=verifyReports(lock,reports(),commit),root=path.resolve('fixture');
 const c=composeFor(selected,root,path.join(root,'fixture.mjs'));
 for(const role of Object.keys(ports)){
  const s=c.services[role];assert.equal(s.build,undefined);assert.equal(s.image,selected[role].image);
  assert.deepEqual(s.healthcheck.test,['CMD',selected[role].healthcheck]);
  assert.equal(s.volumes.length,1);assert.equal(s.volumes[0].source,path.join(root,'services',role+'.json'));
  assert.equal(s.volumes[0].bind.create_host_path,false);assert.equal(s.environment.DATABASE_URL,undefined);
 }
 assert.deepEqual(migrationArguments('runtime','agentos_ci'),['--role','agentos_ci_runtime','--worker-role','agentos_ci_worker']);
 assert.deepEqual(migrationArguments('knowledge','agentos_ci'),['--role','agentos_ci_knowledge','--indexer-role','agentos_ci_indexer']);
 assert.throws(()=>migrationArguments('worker','agentos_ci'));
});
test('stale, missing, duplicated and incompatible reports cannot become deployment inputs',()=>{
 for(const mutate of [r=>r.pop(),r=>r.push(r[0]),r=>r[0].integration_commit='b'.repeat(40),r=>r[0].passed=false,r=>r[0].services[0].commit='b'.repeat(40),r=>r[0].services[0].uid='0',r=>r[0].services[0].healthcheck='/missing',r=>r[0].services[0].image_archive_sha256='',r=>r[0].services[0].binary_checks=[]]){
  const r=reports();mutate(r);assert.throws(()=>verifyReports(lock,r,commit));
 }
});
