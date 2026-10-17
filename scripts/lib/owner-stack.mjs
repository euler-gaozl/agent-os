// Deployment composition only: no application SQL, schemas or framework code.
import assert from 'node:assert/strict';
import path from 'node:path';
import {matrix} from '../owner-build-matrix.mjs';
export const ports={control:8090,toolhub:8091,storage:8092,sandbox:8093,runtime:8094,knowledge:8095,registry:8096,indexer:8097,futures:8098,worker:8099,telemetry:8100,sources:8101};
export const domains=['registry','runtime','toolhub','knowledge','storage','sandbox','telemetry','sources'];
export const ownerOf=role=>role==='worker'?'runtime':role==='indexer'?'knowledge':['control','futures'].includes(role)?null:role;
export function verifyReports(lock,reports,commit){
 const selected=matrix(lock).include;
 assert.equal(reports.length,12,'Exactly twelve owner reports required');
 const result={};
 for(const entry of selected){
  const found=reports.filter(r=>r.services?.[0]?.role===entry.role);
  assert.equal(found.length,1,'Missing or duplicated owner report');
  const report=found[0],s=report.services[0],app=['worker','control','futures'].includes(entry.role),base=app?'/app':'/usr/local/bin';
  assert.equal(report.passed,true);assert.equal(report.integration_commit,commit);assert.equal(report.services.length,1);
  assert.equal(s.repository,entry.repository);assert.equal(s.commit,entry.commit);assert.equal(s.executables_checked,true);
  assert.match(s.image,/^sha256:[a-f0-9]{64}$/);assert.match(s.image_archive_sha256??'',/^[a-f0-9]{64}$/);
  assert.equal(s.uid,app?'10001':'65532');assert.equal(s.user,app?'10001':'65532:65532');
  assert.equal(s.entrypoint,base+'/service');assert.equal(s.healthcheck,base+'/healthcheck');
  assert.equal(s.migration_owner,ownerOf(entry.role)??'none');
  assert.equal(s.migrator,domains.includes(entry.role)?base+'/migrate':null);
  assert.equal(s.binary_checks?.length,domains.includes(entry.role)?3:2);
  result[entry.role]=s;
 }
 return result;
}
export function migrationArguments(role,prefix){
 assert(domains.includes(role));assert.match(prefix,/^agentos_[a-z][a-z0-9_]{0,23}$/);
 const args=['--role',prefix+'_'+role];
 if(role==='runtime')args.push('--worker-role',prefix+'_worker');
 if(role==='knowledge')args.push('--indexer-role',prefix+'_indexer');
 return args;
}
export function composeFor(owners,root,fixture){
 assert.equal(Object.keys(owners).length,12);
 assert(path.isAbsolute(root)&&path.isAbsolute(fixture));
 const services={
  postgres:{image:'postgres:18',environment:{POSTGRES_USER:'provision_fixture',POSTGRES_DB:'postgres',POSTGRES_PASSWORD:'disposable-owner-stack-only',POSTGRES_HOST_AUTH_METHOD:'scram-sha-256'},command:['postgres','-c','shared_buffers=128MB','-c','work_mem=4MB','-c','max_connections=80'],volumes:['postgres-data:/var/lib/postgresql'],healthcheck:{test:['CMD','pg_isready','-U','provision_fixture','-d','postgres'],interval:'3s',timeout:'3s',retries:20},restart:'unless-stopped',mem_limit:'512m',cpus:0.40},
  fixture:{image:'node:24-alpine',command:['node','/fixture.mjs'],volumes:[{type:'bind',source:fixture,target:'/fixture.mjs',read_only:true,bind:{create_host_path:false}}],read_only:true,mem_limit:'128m',cpus:0.10},
 };
 for(const [role,port] of Object.entries(ports)){
  const s=owners[role];assert(s);
  services[role]={image:s.image,pull_policy:'never',restart:'unless-stopped',init:true,read_only:true,tmpfs:['/tmp:size=32m,mode=1777'],security_opt:['no-new-privileges:true'],cap_drop:['ALL'],pids_limit:128,mem_limit:role==='worker'?'384m':'128m',cpus:role==='worker'?0.375:['runtime','toolhub'].includes(role)?0.04:role==='sources'?0.05:0.08,stop_grace_period:'15s',volumes:[{type:'bind',source:path.join(root,'services',role+'.json'),target:'/run/service.json',read_only:true,bind:{create_host_path:false}}],environment:{DEV_LOCAL:'0',LISTEN:'0.0.0.0:'+port,HEALTH_URL:'http://127.0.0.1:'+port+'/readyz',HEALTH_TOKEN_KEY:role==='control'?'ADMIN_TOKEN':role==='futures'?'BUSINESS_TOKEN':'SERVICE_TOKEN'},healthcheck:{test:['CMD',s.healthcheck],interval:'5s',timeout:'4s',retries:12,start_period:'10s'},logging:{driver:'json-file',options:{'max-size':'10m','max-file':'3'}},depends_on:{postgres:{condition:'service_healthy'}}};
  if(['worker','runtime','toolhub'].includes(role))services[role].deploy={replicas:2};
  if(['control','futures'].includes(role))services[role].ports=['127.0.0.1:'+port+':'+port];
 }
 return {name:'agentos-owner-ci',services,volumes:{'postgres-data':{}}};
}
