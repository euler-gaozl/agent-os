// Provision an empty, owner-only database BEFORE starting the disposable CI
// services. Never applies to a local deployment or migrates user data.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
const exec=(file,args)=>execFileSync(file,args,{encoding:'utf8',timeout:120000,stdio:['pipe','pipe','pipe']}).trim();
const dc=(...args)=>exec('docker',['compose','-f','compose.yaml','-f','deploy/compose.ci.yaml',...args]);
const sql=(database,query)=>dc('exec','-T','postgres','psql','-U','agentos','-d',database,'-At','-v','ON_ERROR_STOP=1','-c',query);
if(process.env.GITHUB_ACTIONS!=='true'||process.env.POSTGRES_PASSWORD!=='disposable-ci-database-only')throw Error('Disposable GitHub CI only');
const configPath='.state/services/storage.json';
const config=JSON.parse(fs.readFileSync(configPath,'utf8'));
const url=new URL(config.DATABASE_URL);
assert.equal(url.pathname,'/agentos');
assert.equal(sql('agentos','SELECT (SELECT count(*) FROM public.artifacts)+(SELECT count(*) FROM public.artifact_refs)+(SELECT count(*) FROM public.knowledge_files)+(SELECT count(*) FROM public.knowledge_chunks)'), '0', 'Refuse to discard retained or legacy knowledge data');
sql('agentos','CREATE DATABASE agentos_storage_ci');
url.pathname='/agentos_storage_ci';config.DATABASE_URL=url.href;
const ddl=new URL(url);ddl.username='agentos';ddl.password=process.env.POSTGRES_PASSWORD;
dc('run','--rm','--no-deps','--entrypoint','/app/service','-e','DATABASE_URL='+ddl.href,'migrate','--service','storage');
assert.equal(sql('agentos_storage_ci',"SELECT to_regclass('documents') IS NULL AND to_regclass('runs') IS NULL AND to_regclass('calls') IS NULL"),'t');
assert.equal(sql('agentos_storage_ci',"SELECT has_table_privilege('agentos_runtime','artifacts','SELECT') OR has_table_privilege('agentos_worker','artifact_refs','INSERT')"),'f');
assert.equal(sql('agentos',"SELECT has_table_privilege('agentos_storage','documents','SELECT') OR has_table_privilege('agentos_storage','documents','INSERT')"),'f');
// Reproduce an old installation's grants, then execute the explicit final
// rollout step. An expand-only migration must not revoke them prematurely.
sql('agentos','GRANT SELECT,INSERT,UPDATE,DELETE ON public.documents TO agentos_storage');
dc('run','--rm','--no-deps','--entrypoint','/app/service','migrate','--retire-storage-notes');
assert.equal(sql('agentos',"SELECT has_table_privilege('agentos_storage','documents','SELECT,INSERT,UPDATE,DELETE')"),'f');
// Bootstrap legacy tables are empty. Removing them means a hidden direct SQL
// fallback fails even if future provisioning accidentally broadens privileges.
// These are empty legacy public tables, not the live knowledge schema. Drop
// named dependants first; never use CASCADE to hide an unexpected dependency.
sql('agentos','DROP TABLE public.knowledge_chunks; DROP TABLE public.knowledge_files; DROP TABLE public.artifact_refs; DROP TABLE public.artifacts');
assert.equal(sql('agentos',"SELECT to_regclass('artifacts') IS NULL AND to_regclass('artifact_refs') IS NULL"),'t');
const staged='.state/ci-storage-config.json';
fs.writeFileSync(staged,JSON.stringify(config),{mode:0o600});
try{exec('sudo',['install','-m','640','-o','10001','-g',exec('id',['-g']),staged,configPath])}finally{fs.unlinkSync(staged)}
fs.writeFileSync('.state/ci-evidence/storage-database-boundary.json',JSON.stringify({
  storage_database:'agentos_storage_ci',runtime_database:'agentos',
  storage_has_no_notes_runs_calls:true,runtime_has_no_artifact_tables:true,
  storage_denied_note_sql:true,runtime_worker_denied_storage_sql:true,
  scope:'Same PostgreSQL server, separate databases. Physical-node isolation is not tested.',passed:true,
},null,2));
console.log('PASS isolated Storage database, execution notes owned by Runtime and cross-domain SQL denied');
