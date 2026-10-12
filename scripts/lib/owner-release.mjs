import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';

export function contractFor(definition,role){
 assert.equal(definition.format,1);assert(definition.data_contracts?.[role]);
 return normalize({http:definition.http_contract,data:definition.data_contracts[role],engines:role==='worker'?definition.worker_engines:[],tools:['worker','runtime','registry','toolhub','control','futures'].includes(role)?definition.builtin_tools:[]});
}
function normalize(c){
 assert.deepEqual(Object.keys(c).sort(),['data','engines','http','tools']);
 assert.equal(typeof c.http,'string');assert(c.http);assert.equal(typeof c.data,'string');assert(c.data);
 const names=values=>{assert(Array.isArray(values));assert(values.every(x=>typeof x==='string'&&/^[a-zA-Z0-9._-]{1,128}$/.test(x)));assert.equal(new Set(values).size,values.length);return [...values].sort()};
 return {http:c.http,data:c.data,engines:names(c.engines),tools:names(c.tools)};
}
export function ownerReceipt(role,image,report,definition,reportBytes){
 assert.equal(report.passed,true,'Owner build verification did not pass');assert.match(report.integration_commit??'',/^[a-f0-9]{40}$/);
 assert.equal(report.services?.length,1);const s=report.services[0];
 assert.equal(s.role,role,'Owner report belongs to a different service');
 assert.equal(s.repository,role==='control'?'agent-os-console':'agent-os-'+role);assert.match(s.commit,/^[a-f0-9]{40}$/);
 assert.equal(s.image,image.Id,'Owner report does not attest this image');assert(s.executables_checked);
 assert.equal(s.binary_checks?.length,['worker','indexer','control','futures'].includes(role)?2:3);
 assert.deepEqual(normalize(s.contract),contractFor(definition,role),'Owner HTTP/data/execution contract is incompatible');
 const receipt={repository:s.repository,commit:s.commit,contract:normalize(s.contract),user:s.user,uid:s.uid,entrypoint:s.entrypoint,healthcheck:s.healthcheck,report_sha256:createHash('sha256').update(reportBytes).digest('hex')};
 validateOwnerImage(role,image,receipt);
 return receipt;
}
export function validateOwnerImage(role,image,receipt){
 assert.match(image.Id,/^sha256:[a-f0-9]{64}$/);assert.equal(image.Os,'linux');assert.equal(image.Architecture,'amd64');
 const app=['worker','control','futures'].includes(role),base=app?'/app':'/usr/local/bin';
 assert.equal(receipt.repository,role==='control'?'agent-os-console':'agent-os-'+role);assert.match(receipt.commit,/^[a-f0-9]{40}$/);
 assert.equal(receipt.uid,app?'10001':'65532');assert.equal(receipt.user,app?'10001':'65532:65532');
 assert.equal(receipt.entrypoint,base+'/service');assert.equal(receipt.healthcheck,base+'/healthcheck');
 const labels=image.Config.Labels;
 assert.equal(labels['org.agentos.role'],role,'Image belongs to a different Owner');
 assert.equal(labels['org.opencontainers.image.source'],'https://github.com/euler-gaozl/'+receipt.repository);
 assert.equal(labels['org.opencontainers.image.revision'],receipt.commit);
 assert.deepEqual(normalize(JSON.parse(labels['org.agentos.contract'])),normalize(receipt.contract));
 assert.deepEqual(JSON.parse(labels['org.agentos.builtin-tools']).sort(),receipt.contract.tools);
 assert.deepEqual(JSON.parse(labels['org.agentos.worker-engines']).sort(),receipt.contract.engines);
 assert.equal(image.Config.User,receipt.user);assert.deepEqual(image.Config.Entrypoint,[receipt.entrypoint]);
 assert.deepEqual(image.Config.Cmd,['--config','/run/service.json']);assert.deepEqual(image.Config.Healthcheck.Test,['CMD',receipt.healthcheck]);
}
export function requireReleaseTransition(current,next){
 if(!current)return;
 if(current.owner&&!next.owner)throw Error('Cannot replace an attested Owner with an unverified legacy image');
 if(!current.owner&&next.owner)throw Error('Legacy-to-Owner transition needs an explicitly registered compatible baseline; use the reviewed migration procedure');
 if(current.owner)assert.deepEqual(normalize(current.owner.contract),normalize(next.owner.contract),'Owner contracts differ; a coordinated migration is required before release or rollback');
}
