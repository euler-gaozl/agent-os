// Destructive lifecycle is restricted to the NEW disposable GitHub CI project.
// Production/Windows maintenance never calls this script.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {verifyReports,composeFor,migrationArguments,ports,domains} from './lib/owner-stack.mjs';

const root=path.resolve('.state/owner-stack'),compose=path.join(root,'compose.json'),project='agentos-owner-ci';
const evidence=path.resolve('.state/ci-owner-evidence');
const action=process.argv[2],bundleRoot=path.resolve(process.argv[3]??'.state/owner-bundles');
if(process.platform!=='linux'||process.env.GITHUB_ACTIONS!=='true'||process.env.RUNNER_ENVIRONMENT!=='github-hosted')throw Error('Disposable hosted Linux CI only');
if(!['prepare','migrate','diagnose','dispose'].includes(action))throw Error('Unknown owner stack action');
let phase=action;
const run=(program,args,options={})=>execFileSync(program,args,{encoding:'utf8',timeout:240000,maxBuffer:16<<20,stdio:['pipe','pipe','pipe'],...options}).trim();
const docker=(...args)=>run('docker',args);
const dc=(...args)=>docker('compose','-p',project,'-f',compose,...args);
const read=file=>JSON.parse(fs.readFileSync(file,'utf8'));
const write=(file,value)=>fs.writeFileSync(file,JSON.stringify(value,null,2)+'\n',{mode:0o600,flag:'wx'});
const hash=async file=>{const h=createHash('sha256');for await(const b of fs.createReadStream(file))h.update(b);return h.digest('hex')};
const config=role=>read(path.join(root,'bootstrap',role+'.json'));
const sql=(db,q)=>dc('exec','-T','postgres','psql','-X','-U','provision_fixture','-d',db,'-At','-v','ON_ERROR_STOP=1','-c',q);
const schemaHash=db=>createHash('sha256').update(dc('exec','-T','postgres','pg_dump','-U','provision_fixture','-d',db,'--schema-only','--no-owner','--no-comments').split('\n').filter(line=>!/^\\(?:un)?restrict /.test(line)).join('\n')).digest('hex');
function internalRequest(role,route,token,body){
 const code="let t='';for await(const b of process.stdin)t+=b;const p=JSON.parse(t);const r=await fetch(p.url,{method:p.body===undefined?'GET':'POST',headers:{Authorization:'Bearer '+p.token,'Content-Type':'application/json'},body:p.body===undefined?undefined:JSON.stringify(p.body),signal:AbortSignal.timeout(10000)});console.log(JSON.stringify({status:r.status,body:await r.json()}));";
 return JSON.parse(run('docker',['compose','-p',project,'-f',compose,'exec','-T','fixture','node','--input-type=module','-e',code],{input:JSON.stringify({url:'http://'+role+':'+ports[role]+route,token,body})}));
}
try{
 fs.mkdirSync(evidence,{recursive:true,mode:0o700});
 if(action==='prepare'){
  assert(!fs.existsSync(root),'New stack output required');
  assert.equal(docker('ps','-aq','--filter','label=com.docker.compose.project='+project),'','Existing stack refused');
  assert.equal(docker('volume','ls','-q','--filter','label=com.docker.compose.project='+project),'','Retained database volume refused');
  const lock=read('deploy/service-sources.json'),commit=run('git',['rev-parse','HEAD']);
  const reports=Object.keys(ports).map(role=>read(path.resolve('.state/owner-reports','owner-image-'+role,'result.json')));
  const owners=verifyReports(lock,reports,commit);
  fs.mkdirSync(root,{mode:0o700});fs.mkdirSync(path.join(root,'bootstrap'),{mode:0o700});fs.mkdirSync(path.join(root,'services'),{mode:0o700});
  for(const [role,s] of Object.entries(owners)){
   phase='load '+role;
   const archive=path.join(bundleRoot,'owner-bundle-'+role,role+'-image.tar');
   assert.equal(await hash(archive),s.image_archive_sha256,'Image archive differs');
   docker('image','load','--input',archive);
   const image=JSON.parse(docker('image','inspect',s.image))[0];
   assert.equal(image.Id,s.image);assert.equal(image.Config.User,s.user);
   assert.equal(image.Config.Labels['org.opencontainers.image.revision'],s.commit);
   assert.equal(image.Config.Labels['org.agentos.role'],role);
   assert.deepEqual(image.Config.Entrypoint,[s.entrypoint]);assert.deepEqual(image.Config.Healthcheck.Test,['CMD',s.healthcheck]);
  }
  write(path.join(root,'owners.json'),owners);
  write(compose,composeFor(owners,root,path.resolve('scripts/ci-fixture.mjs')));
  const plan={format:1,prefix:'agentos_owner_ci',admin_database_url:'postgres://provision_fixture:disposable-owner-stack-only@postgres:5432/postgres?sslmode=disable',admin_token:'disposable-owner-admin-'+'a'.repeat(32),business_token:'disposable-owner-business-'+'b'.repeat(32),master_key:'c'.repeat(64),endpoints:Object.fromEntries(Object.entries(ports).map(([role,port])=>[role,'http://'+role+':'+port])),options:{runtime:{MCP_ALLOWED_HOSTS:'fixture:8111,sources:8101'},worker:{MCP_ALLOWED_HOSTS:'fixture:8111,sources:8101',AGENTOS_NODE:'/usr/local/bin/node',DSH_RUNNER:'/app/harness/runner.mjs'},toolhub:{MCP_ALLOWED_HOSTS:'fixture:8111,sources:8101'},telemetry:{LANGFUSE_URL:'http://fixture:8111'}}};
  write(path.join(root,'plan.json'),plan);
  phase='database startup';dc('up','-d','--wait','postgres','fixture');
  phase='identity provisioning';
  const provision=path.resolve(process.env.RUNNER_TEMP,'provision');assert(fs.statSync(provision).isFile());
  for(let pass=0;pass<2;pass++)docker('run','--rm','--network',project+'_default','--user',process.getuid()+':'+process.getgid(),'--read-only','--cap-drop','ALL','--security-opt','no-new-privileges','--mount','type=bind,src='+root+',dst=/private','--mount','type=bind,src='+provision+',dst=/provision,readonly','--entrypoint','/provision','postgres:18','--plan','/private/plan.json','--output','/private/bootstrap');
  for(const [role,s] of Object.entries(owners)){
   // Derived deployment copy only. Retained checkpoint/config stays 0600 under
   // the runner identity so retries never loosen its protection or change bytes.
   run('sudo',['install','-m','640','-o',s.uid,'-g',String(process.getgid()),path.join(root,'bootstrap',role+'.json'),path.join(root,'services',role+'.json')]);
  }
  write(path.join(evidence,'provision.json'),{passed:true,provider_calls:0,domains:8,application_roles:10,application_migrations:'not performed',same_checkpoint_replayed:true,integration_commit:commit});
 }
 if(action==='migrate'){
  const owners=read(path.join(root,'owners.json')),plan=read(path.join(root,'plan.json')),targets=read(path.join(root,'bootstrap','migration-targets.json'));
  assert.deepEqual(targets.map(t=>t.owner),domains);
  const report={passed:false,provider_calls:0,migrations:[],scope:'Actual owner migrations twice in eight fresh databases; full service contracts run separately'};
  const schemas=Object.fromEntries(targets.map(t=>[t.owner,schemaHash(t.database)]));
  const configurationHashes=Object.fromEntries(Object.keys(ports).map(role=>[role,createHash('sha256').update(fs.readFileSync(path.join(root,'bootstrap',role+'.json'))).digest('hex')]));
  for(const t of targets){
   phase='owner migration '+t.owner;const owner=owners[t.owner];
   assert.equal(t.database,plan.prefix+'_'+t.owner);assert(owner.migrator);
   const url=new URL(plan.admin_database_url);url.pathname='/'+t.database;
   let migrated;
   for(let pass=0;pass<2;pass++){
    run('docker',['run','--rm','--network',project+'_default','--read-only','--cap-drop','ALL','--security-opt','no-new-privileges','--env','MIGRATION_DATABASE_URL','--entrypoint',owner.migrator,owner.image,...migrationArguments(t.owner,plan.prefix)],{env:{...process.env,MIGRATION_DATABASE_URL:url.href}});
    const observed=schemaHash(t.database);if(pass===1)assert.equal(observed,migrated,'Repeated migration changed schema or grants');migrated=observed;
   }
   for(const other of targets.filter(x=>x.owner!==t.owner))assert.equal(schemaHash(other.database),schemas[other.owner],'Owner migration changed another database schema');
   schemas[t.owner]=migrated;
   for(const role of Object.keys(ports))assert.equal(createHash('sha256').update(fs.readFileSync(path.join(root,'bootstrap',role+'.json'))).digest('hex'),configurationHashes[role],'Migration changed a retained configuration');
   const tables=sql(t.database,"SELECT schemaname||'.'||tablename FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1").split('\n').filter(Boolean);assert(tables.length>0);
   report.migrations.push({role:t.owner,commit:owner.commit,image:owner.image,database:t.database,passes:2,tables,schema_sha256:migrated,other_domains_unchanged:true,configuration_unchanged:true});
  }
  phase='start all independent owners';dc('up','-d','--no-build','--wait','--wait-timeout','150');
  // Seed only fixture credentials through Registry HTTP. Compare resolved
  // values first, so repeated bootstrap does not rewrite an existing secret.
  const values={SOURCES_MCP_TOKEN:config('sources').SERVICE_TOKEN,LANGFUSE_PUBLIC_KEY:'ci-public',LANGFUSE_SECRET_KEY:'ci-secret'};
  let changes=0;
  for(let pass=0;pass<2;pass++)for(const [name,value] of Object.entries(values)){
   phase='Registry fixture credential comparison';
   const existing=internalRequest('registry','/v1/credentials/resolve',config('runtime').SERVICE_TOKEN,{name});
   if(existing.status===200){assert(existing.body.value===value,'Existing credential differs');continue;}
   assert([400,404].includes(existing.status),'Credential comparison failed');
   const stored=internalRequest('registry','/v1/credentials',config('control').SERVICE_TOKEN,{name,value});assert.equal(stored.status,200);changes++;
  }
  assert.equal(changes,3);report.fixture_credentials_written=3;report.second_seed_writes=0;report.passed=true;
  write(path.join(evidence,'migrations.json'),report);
 }
 if(action==='diagnose'){
  if(fs.existsSync(compose)){
   const ids=dc('ps','-aq').split('\n').filter(Boolean);
   if(ids.length){
    const containers=JSON.parse(docker('inspect',...ids)).map(c=>({id:c.Id,image:c.Image,service:c.Config.Labels['com.docker.compose.service'],user:c.Config.User,status:c.State.Status,health:c.State.Health?.Status,restarts:c.RestartCount,exit_code:c.State.ExitCode}));
    write(path.join(evidence,'containers.json'),containers);
   }
  }
 }
 if(action==='dispose'){
  if(fs.existsSync(compose))dc('down','--volumes','--remove-orphans');
 }
 console.log('PASS independent owner stack '+action);
}catch{
 fs.mkdirSync(evidence,{recursive:true,mode:0o700});
 fs.writeFileSync(path.join(evidence,'failure-'+action+'.json'),JSON.stringify({passed:false,phase,details:'Command and credential values withheld; private fixture state remains on this disposable runner.'},null,2));
 console.error('Independent owner stack failed at '+phase+'; command/configuration values withheld.');process.exitCode=1;
}
