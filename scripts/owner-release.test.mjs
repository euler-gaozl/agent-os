import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {contractFor,ownerReceipt,validateOwnerImage,requireReleaseTransition} from './lib/owner-release.mjs';
const definition=JSON.parse(fs.readFileSync(new URL('../deploy/windows-release-contracts.json',import.meta.url),'utf8'));
function fixture(role){
 const contract=contractFor(definition,role),app=['worker','control','futures'].includes(role),base=app?'/app':'/usr/local/bin';
 const service={role,repository:role==='control'?'agent-os-console':'agent-os-'+role,commit:'b'.repeat(40),image:'sha256:'+'a'.repeat(64),executables_checked:true,binary_checks:Array(['worker','indexer','control','futures'].includes(role)?2:3).fill({}),contract,uid:app?'10001':'65532',user:app?'10001':'65532:65532',entrypoint:base+'/service',healthcheck:base+'/healthcheck'};
 const image={Id:service.image,Os:'linux',Architecture:'amd64',Config:{User:service.user,Entrypoint:[service.entrypoint],Cmd:['--config','/run/service.json'],Healthcheck:{Test:['CMD',service.healthcheck]},Labels:{'org.agentos.role':role,'org.opencontainers.image.source':'https://github.com/euler-gaozl/'+service.repository,'org.opencontainers.image.revision':service.commit,'org.agentos.contract':JSON.stringify(contract),'org.agentos.builtin-tools':JSON.stringify(contract.tools),'org.agentos.worker-engines':JSON.stringify(contract.engines)}}};
 return {image,report:{passed:true,integration_commit:'c'.repeat(40),services:[service]}};
}
test('all Owner releases require attested identity, exact complete contracts and owner-specific executables',()=>{
 for(const role of Object.keys(definition.data_contracts).filter(x=>x!=='migrate-services')){
  const {image,report}=fixture(role);const receipt=ownerReceipt(role,image,report,definition,JSON.stringify(report));validateOwnerImage(role,image,receipt);
  for(const mutate of [x=>x.Config.User='0',x=>x.Config.Entrypoint=['/wrong'],x=>x.Config.Healthcheck.Test=['NONE'],x=>x.Config.Labels['org.agentos.role']='wrong',x=>x.Config.Labels['org.opencontainers.image.revision']='d'.repeat(40),x=>x.Config.Labels['org.agentos.builtin-tools']='["other"]']){
   const bad=structuredClone(image);mutate(bad);assert.throws(()=>validateOwnerImage(role,bad,receipt));
  }
  const bad=structuredClone(report);bad.services[0].contract.data='changed-schema';assert.throws(()=>ownerReceipt(role,image,bad,definition,JSON.stringify(bad)));
 }
});
test('unknown legacy contracts and incompatible retained schemas cannot enter an automatic rollback path',()=>{
 const legacy={image:'old'},owner={owner:{contract:contractFor(definition,'runtime')}};
 requireReleaseTransition(null,owner);requireReleaseTransition(owner,structuredClone(owner));requireReleaseTransition(legacy,legacy);
 assert.throws(()=>requireReleaseTransition(legacy,owner),/explicitly registered compatible baseline/);
 assert.throws(()=>requireReleaseTransition(owner,legacy),/unverified legacy/);
 const changed=structuredClone(owner);changed.owner.contract.data='next-schema';
 assert.throws(()=>requireReleaseTransition(owner,changed),/coordinated migration/);
 assert.throws(()=>requireReleaseTransition(changed,owner),/coordinated migration/);
});
