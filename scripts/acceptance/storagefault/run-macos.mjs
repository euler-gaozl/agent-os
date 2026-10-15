// Reviewed opt-in Mac fault controller. It never uses the existing cluster or
// a supplied mount path. Do not run until the controller and Go test are reviewed.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import net from 'node:net';
import crypto from 'node:crypto';
import {spawn} from 'node:child_process';

if(process.platform!=='darwin'||process.arch!=='arm64')throw Error('This fixture is for the reviewed Mac arm64 environment');
if(process.argv.length!==4||process.argv[2]!=='--run-reviewed-fixture')throw Error('Usage: node run-macos.mjs --run-reviewed-fixture /absolute/agent-platform');
const platform=process.argv[3];
if(!path.isAbsolute(platform)||platform===path.parse(platform).root||path.resolve(platform)!==platform||!/^[A-Za-z0-9_./-]+$/.test(platform)||fs.realpathSync(platform)!==platform)throw Error('Explicit physical workspace path without whitespace required');
const nonce=crypto.randomBytes(16).toString('hex');
const root=`${platform}/local/data/storage-enospc-${nonce}`;
const evidence=`${platform}/local/evidence/storage-enospc-${nonce}`;
const mount=`${root}/volume`,image=`${root}/volume.dmg`,pgdata=`${mount}/pgdata`,marker=`${mount}/.agentos-enospc`;
const pgbin=`${platform}/local/toolchains/postgresql-18.6/bin`;
const storage=`${platform}/local/mac-dev-stack/bin/storage`,migrator=`${platform}/local/mac-dev-stack/bin/storage-migrate`;
const go=`${platform}/local/toolchains/go1.27.2/bin/go`;
const testSource=fileURLToPath(new URL('./storage_enospc_test.go',import.meta.url));
const cap=512*1024*1024;
const secrets=[];const secret=()=>{const s=crypto.randomBytes(32).toString('hex');secrets.push(s);return s};
const adminPass=secret(),appPass=secret(),serviceToken=secret(),writerToken=secret(),readerToken=secret();
const clean={PATH:'/usr/bin:/bin:/usr/sbin:/sbin',LANG:'C',LC_ALL:'C'};
let device='',volumeDev,storageChild,storageClosed,interrupted=false,cleaning=false;
let attachmentAttempted=false,pgStartAttempted=false,rootCreated=false,evidenceCreated=false;
const active=new Set();const checks=[],evidenceErrors=[];
const scrub=s=>secrets.reduce((v,k)=>v.replaceAll(k,'<fixture-secret>'),String(s)).replace(/postgres(?:ql)?:\/\/[^\s"']+/g,'<fixture-dsn>');
const save=(name,v)=>fs.writeFileSync(`${evidence}/${name}`,JSON.stringify(v,null,2)+'\n',{mode:0o600});
const sha=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));

function killCommand(child){if(child.pid&&child.exitCode===null&&child.signalCode===null){try{process.kill(-child.pid,'SIGKILL')}catch(e){if(e.code!=='ESRCH')throw e}}}
function interrupt(){if(cleaning||interrupted)return;interrupted=true;for(const c of active)killCommand(c)}
process.on('SIGINT',interrupt);process.on('SIGTERM',interrupt);
const totalTimer=setTimeout(interrupt,240000);

async function run(label,binary,args,{timeout=30000,input,env=clean,record=true,allowFailure=false,cwd=root}={}){
  if(interrupted&&!cleaning)throw Error('Fixture interrupted');
  const child=spawn(binary,args,{env,cwd,detached:true,stdio:['pipe','pipe','pipe']});active.add(child);
  let out='',err='',limitError=false,timedOut=false;
  const append=(which,b)=>{if(out.length+err.length+b.length>8*1024*1024){limitError=true;killCommand(child);return}if(which==='out')out+=b;else err+=b};
  child.stdout.on('data',b=>append('out',b));child.stderr.on('data',b=>append('err',b));
  child.stdin.on('error',()=>{}); // A failed subprocess may close stdin before receiving its input.
  const timer=setTimeout(()=>{timedOut=true;killCommand(child)},timeout);
  const result=await new Promise(resolve=>{child.once('error',error=>resolve({error:error.code}));child.once('close',(code,signal)=>resolve({code,signal})) ;child.stdin.end(input);});
  clearTimeout(timer);active.delete(child);
  checks.push({label,...result,timedOut,limitError});
  try{
    if(record)fs.writeFileSync(`${evidence}/${label}.log`,scrub(out+err),{mode:0o600});
    save('commands.json',checks);
  }catch(e){evidenceErrors.push(`${label}: ${scrub(e.message)}`);if(!cleaning)throw e}
  if((result.code!==0||timedOut||limitError)&&!allowFailure)throw Error(`${label} failed (${result.code??result.error}; timeout=${timedOut})`);
  return {out,err,...result};
}
async function plist(label,args){const p=await run(label,'/usr/bin/hdiutil',args,{record:false});const j=await run(`${label}-parse`,'/usr/bin/plutil',['-convert','json','-o','-','--','-'],{input:p.out,record:false});return JSON.parse(j.out)}
async function port(){const s=net.createServer();await new Promise((r,j)=>s.once('error',j).listen(0,'127.0.0.1',r));const p=s.address().port;await new Promise(r=>s.close(r));return p}

function ownRoot(){
  const s=fs.lstatSync(root);if(!s.isDirectory()||s.isSymbolicLink()||fs.realpathSync(root)!==root)throw Error('Fixture root identity changed');
  if(fs.readFileSync(`${root}/.fixture-owner`,'utf8')!==nonce)throw Error('Fixture owner marker changed');
}
function ownVolume(){
  ownRoot();const s=fs.lstatSync(mount);
  if(!s.isDirectory()||s.isSymbolicLink()||fs.realpathSync(mount)!==mount||s.dev!==volumeDev||s.dev===fs.statSync(root).dev||fs.readFileSync(marker,'utf8')!==nonce)throw Error('Fixture volume identity changed');
  const st=fs.statfsSync(mount);if(st.blocks*st.bsize>cap)throw Error('Volume exceeds fixed 512 MiB bound');
  return st;
}
async function mountedImage(){
  const info=await plist('image-info',['info','-plist']);
  const matching=(info.images??[]).filter(x=>x['image-path']===image);
  if(matching.length===0)return null;
  if(matching.length!==1)throw Error('Ambiguous fixture image attachment');
  const entries=matching[0]['system-entities']??[];
  const mounted=entries.find(e=>e['mount-point']===mount);
  if(entries.some(e=>e['mount-point']&&e['mount-point']!==mount))throw Error('Fixture image mounted outside its private path');
  const discovered=entries.find(e=>/^\/dev\/disk\d+$/.test(e['dev-entry']??''))?.['dev-entry']??mounted?.['dev-entry'];
  if(!/^\/dev\/disk\d+(s\d+)?$/.test(discovered??''))throw Error('Unexpected fixture device identity');
  if(device&&device!==discovered)throw Error('Image device identity changed');
  device=discovered;
  if(mounted){
    const st=fs.lstatSync(mount);if(st.isSymbolicLink()||!st.isDirectory()||fs.realpathSync(mount)!==mount||st.dev===fs.statSync(root).dev)throw Error('Fixture mount identity changed');
    if(volumeDev!==undefined&&st.dev!==volumeDev)throw Error('Volume device identity changed');
    volumeDev=st.dev;
  }else if(pgStartAttempted)throw Error('Started PostgreSQL volume is no longer mounted');
  return matching[0];
}
async function checkPG(allowStopped=false){
  ownVolume();const file=`${pgdata}/postmaster.pid`;
  if(!fs.existsSync(file)){if(allowStopped)return null;throw Error('Postmaster identity missing')}
  const lines=fs.readFileSync(file,'utf8').split('\n'),pid=Number(lines[0]);
  if(!Number.isInteger(pid)||pid<=1||lines[1]!==pgdata)throw Error('Postmaster identity changed');
  const r=await run('postgres-identity','/bin/ps',['-p',String(pid),'-o','command='],{record:false,allowFailure:true});
  if(r.code!==0&&allowStopped&&pidAbsent(pid))return null;
  const fields=r.out.trim().split(/\s+/),i=fields.indexOf('-D');
  if(r.code!==0||fields[0]!==`${pgbin}/postgres`||i<0||fields[i+1]!==pgdata)throw Error('Refusing to stop an unrelated PostgreSQL process');
  return pid;
}
function pidAbsent(pid){
  try{process.kill(pid,0);return false}catch(e){if(e.code==='ESRCH')return true;throw Error('Unable to establish fixture PID absence')}
}
async function stopStorage(){
  if(!storageChild||!storageChild.pid)return;
  if(storageChild.exitCode===null&&storageChild.signalCode===null){
    const r=await run('storage-identity','/bin/ps',['-p',String(storageChild.pid),'-o','command='],{record:false,allowFailure:true});
    if(r.code===0&&r.out.trim()!==`${storage} --config ${root}/storage.json`)throw Error('Refusing to stop an unrelated Storage process');
    if(r.code!==0&&!pidAbsent(storageChild.pid))throw Error('Unable to verify Storage process identity');
    if(r.code===0)storageChild.kill('SIGTERM');
    if(!await Promise.race([storageClosed.then(()=>true),sleep(5000).then(()=>false)])){
      const again=await run('storage-identity-before-kill','/bin/ps',['-p',String(storageChild.pid),'-o','command='],{record:false,allowFailure:true});
      if(again.code===0&&again.out.trim()===`${storage} --config ${root}/storage.json`)storageChild.kill('SIGKILL');
      else if(again.code===0||!pidAbsent(storageChild.pid))throw Error('Refusing kill without the fixture Storage identity');
      if(!await Promise.race([storageClosed.then(()=>true),sleep(5000).then(()=>false)]))throw Error('Fixture Storage did not exit');
    }
  }
  await storageClosed;
}

let failure;
const cleanup={storage_stopped:false,postgres_stopped:false,image_detached:false,fixture_removed:false};
try{
  if(fs.realpathSync(`${platform}/local/data`)!==`${platform}/local/data`)throw Error('Data parent must be physical');
  if(fs.realpathSync(`${platform}/local/evidence`)!==`${platform}/local/evidence`)throw Error('Evidence parent must be physical');
  const host=fs.statfsSync(`${platform}/local/data`);if(host.bavail*host.bsize<2*1024*1024*1024)throw Error('At least 2 GiB host free space required before bounded image creation');
  fs.mkdirSync(evidence,{mode:0o700});evidenceCreated=true;
  fs.mkdirSync(root,{mode:0o700});rootCreated=true;fs.writeFileSync(`${root}/.fixture-owner`,nonce,{mode:0o600,flag:'wx'});
  if(sha(storage)!=='ea1fe73fb69859180d6c0bba35cc7f932d0a3818e591809d7e7d0f8556dd1131'||sha(migrator)!=='5acbc82e170e29352ae6a53076961afbc61d07e1471395c206190e4ef12e7412')throw Error('Fixed Storage build hashes changed');
  const version=await run('postgres-version',`${pgbin}/postgres`,['--version']);if(!/^postgres \(PostgreSQL\) 18\.6\s*$/.test(version.out))throw Error('PostgreSQL version changed');
  save('inputs.json',{os:process.platform,arch:process.arch,storage_sha256:sha(storage),migrator_sha256:sha(migrator),test_sha256:sha(testSource),controller_sha256:sha(new URL(import.meta.url)),host_free_bytes:host.bavail*host.bsize,image_limit_bytes:cap,real_provider_calls:0});
  await run('compile',go,['test','-mod=vendor','-c','-o',`${evidence}/storage-enospc.test`,testSource],{timeout:60000,cwd:`${platform}/repos/agent-os-storage`,env:{...clean,GOWORK:'off',GOTOOLCHAIN:'local',GOPROXY:'off',GOCACHE:`${platform}/local/cache/go-build`,GOMODCACHE:`${platform}/local/cache/go-mod`},});
  ownRoot();fs.mkdirSync(mount,{mode:0o700});
  const beforeImage=fs.statfsSync(`${platform}/local/data`);if(beforeImage.bavail*beforeImage.bsize<2*1024*1024*1024)throw Error('Host free space fell below 2 GiB before image creation');
  // 511 MiB leaves room for the UDIF trailer inside the 512 MiB file bound.
  await run('image-create','/usr/bin/hdiutil',['create','-size','511m','-type','UDIF','-fs','Journaled HFS+','-volname',`AgentOS-${nonce.slice(0,8)}`,'-nospotlight',image]);
  const im=fs.lstatSync(image);if(!im.isFile()||im.isSymbolicLink()||im.size>cap)throw Error('Image is not a bounded regular file');
  attachmentAttempted=true;
  const attached=await plist('image-attach',['attach',image,'-mountpoint',mount,'-noautoopen','-plist']);
  const entities=attached['system-entities']??[],mounted=entities.find(e=>e['mount-point']===mount);
  if(!mounted)throw Error('Image did not mount at the private fixture path');
  device=entities.find(e=>/^\/dev\/disk\d+$/.test(e['dev-entry']??''))?.['dev-entry']??mounted['dev-entry'];
  if(!/^\/dev\/disk\d+(s\d+)?$/.test(device))throw Error('Unexpected fixture device identity');
  volumeDev=fs.statSync(mount).dev;fs.writeFileSync(marker,nonce,{mode:0o600,flag:'wx'});ownVolume();await mountedImage();
  save('volume.json',{image,device,mount,volume_device:volumeDev,image_file_bytes:im.size,volume_capacity_bytes:fs.statfsSync(mount).blocks*fs.statfsSync(mount).bsize});
  const pgPort=await port();let storagePort=await port();while(storagePort===pgPort)storagePort=await port();
  fs.writeFileSync(`${root}/admin-password`,adminPass,{mode:0o600,flag:'wx'});
  await run('initdb',`${pgbin}/initdb`,['-D',pgdata,'--no-locale','--encoding=UTF8','-U','enospc_admin','--auth=scram-sha-256','--pwfile',`${root}/admin-password`]);
  ownVolume();
  // TCP only: a nonce-scoped socket pathname would exceed Darwin's socket limit.
  fs.appendFileSync(`${pgdata}/postgresql.conf`,`\nlisten_addresses='127.0.0.1'\nport=${pgPort}\nunix_socket_directories=''\nshared_buffers='16MB'\nmax_connections=12\nmax_wal_size='64MB'\nmin_wal_size='32MB'\nlog_statement='none'\nlog_error_verbosity='verbose'\nlog_parameter_max_length_on_error=0\n`);
  const pgLog=`${root}/postgres.log`;pgStartAttempted=true;await run('postgres-start',`${pgbin}/pg_ctl`,['-D',pgdata,'-l',pgLog,'start','-w','-t','15']);await checkPG();
  const pgEnv={...clean,PGHOST:'127.0.0.1',PGPORT:String(pgPort),PGUSER:'enospc_admin',PGPASSWORD:adminPass,PGDATABASE:'postgres',PGSSLMODE:'disable'};
  await run('database-create',`${pgbin}/psql`,['-X','-q','--set','ON_ERROR_STOP=1'],{env:pgEnv,input:`CREATE ROLE enospc_storage LOGIN PASSWORD '${appPass}';\nCREATE DATABASE enospc_storage TEMPLATE template0;\n`});
  const dsn=(user,pass,db)=>`postgres://${user}:${pass}@127.0.0.1:${pgPort}/${db}?sslmode=disable`;
  const adminURL=dsn('enospc_admin',adminPass,'postgres'),databaseURL=dsn('enospc_admin',adminPass,'enospc_storage');
  await run('owner-migrate',migrator,['--role','enospc_storage'],{env:{...clean,MIGRATION_DATABASE_URL:databaseURL}});
  const storageURL=`http://127.0.0.1:${storagePort}`;
  const tokenHash=s=>crypto.createHash('sha256').update(s).digest('hex');
  // Heartbeats stay inside this fixture. No default legacy localhost service is contacted.
  fs.writeFileSync(`${root}/storage.json`,JSON.stringify({LISTEN:`127.0.0.1:${storagePort}`,DATABASE_URL:dsn('enospc_storage',appPass,'enospc_storage'),SERVICE_TOKEN:serviceToken,SERVICE_PEERS:JSON.stringify({storage:tokenHash(serviceToken),runtime:tokenHash(writerToken),control:tokenHash(readerToken)}),RUNTIME_URL:storageURL,REGISTRY_URL:storageURL,INSTANCE_ID:`storage-enospc-${nonce}`,DB_MAX_CONNS:'2',GOMEMLIMIT:'96MiB'}),{mode:0o600,flag:'wx'});
  const storageLog=fs.openSync(`${root}/storage.log`,'wx',0o600);
  storageChild=spawn(storage,['--config',`${root}/storage.json`],{env:clean,cwd:root,stdio:['ignore',storageLog,storageLog]});fs.closeSync(storageLog);
  storageClosed=new Promise(resolve=>{storageChild.once('error',error=>resolve({error:error.code}));storageChild.once('close',(code,signal)=>resolve({code,signal}))});
  let ready=false;for(let i=0;i<100;i++){if(interrupted)throw Error('Fixture interrupted');if(!storageChild.pid||storageChild.exitCode!==null||storageChild.signalCode!==null)throw Error('Storage exited before readiness');try{const r=await fetch(`${storageURL}/readyz`,{headers:{Authorization:`Bearer ${readerToken}`},signal:AbortSignal.timeout(1000),redirect:'error'});if(r.status===200){ready=true;break}}catch{}await sleep(50)}if(!ready)throw Error('Storage readiness timeout');
  fs.writeFileSync(`${root}/fixture.json`,JSON.stringify({Root:root,Mount:mount,Image:image,Marker:marker,Nonce:nonce,PGData:pgdata,PGBin:pgbin,PGLog:pgLog,Evidence:evidence,AdminURL:adminURL,DatabaseURL:databaseURL,StorageURL:storageURL,WriterToken:writerToken,ReaderToken:readerToken,VolumeDev:volumeDev,Port:pgPort}),{mode:0o600,flag:'wx'});
  save('processes.json',{storage_pid:storageChild.pid,postgres_pid:await checkPG(),pgdata,pg_port:pgPort,storage_port:storagePort});
  await run('test',`${evidence}/storage-enospc.test`,['-test.v','-test.timeout=115s'],{timeout:125000,env:{...clean,STORAGE_ENOSPC_FIXTURE:`${root}/fixture.json`,STORAGE_ENOSPC_WORKSPACE:platform}});
}catch(error){failure=scrub(error.message)}finally{
  clearTimeout(totalTimer);cleaning=true;
  if(evidenceCreated){
    try{await stopStorage();cleanup.storage_stopped=true}catch(e){cleanup.storage_error=scrub(e.message)}
    try{if(pgStartAttempted){const pid=await checkPG(true);if(pid)await run('postgres-stop',`${pgbin}/pg_ctl`,['-D',pgdata,'stop','-m','immediate','-w','-t','10']);if(await checkPG(true))throw Error('Fixture PostgreSQL is still active')}cleanup.postgres_stopped=true}catch(e){cleanup.postgres_error=scrub(e.message)}
    for(const name of ['postgres.log','storage.log']){
      try{if(fs.existsSync(`${root}/${name}`))fs.writeFileSync(`${evidence}/${name}`,scrub(fs.readFileSync(`${root}/${name}`,'utf8')),{mode:0o600})}
      catch(e){evidenceErrors.push(`${name}: ${scrub(e.message)}`)}
    }
    try{
      if(attachmentAttempted&&await mountedImage()){
        if(!cleanup.storage_stopped||!cleanup.postgres_stopped)throw Error('Refusing detach while fixture processes are unconfirmed');
        ownRoot();if(pgStartAttempted)ownVolume();const detached=await run('image-detach','/usr/bin/hdiutil',['detach',device],{allowFailure:true});
        if(detached.code!==0){if(!await mountedImage())throw Error('Attachment changed during detach');ownRoot();if(pgStartAttempted)ownVolume();await run('image-detach-force','/usr/bin/hdiutil',['detach',device,'-force'])}
        if(await mountedImage())throw Error('Fixture image remains attached');
      }
      // Never recursively delete through a mount, including an unparsed attach result.
      if(fs.existsSync(mount)&&fs.statSync(mount).dev!==fs.statSync(root).dev)throw Error('Private mountpoint still belongs to a different device');
      cleanup.image_detached=true;
    }catch(e){cleanup.detach_error=scrub(e.message)}
    try{if(cleanup.storage_stopped&&cleanup.postgres_stopped&&cleanup.image_detached){if(rootCreated){ownRoot();fs.rmSync(root,{recursive:true})}cleanup.fixture_removed=true}}catch(e){cleanup.remove_error=scrub(e.message)}
    let success=!failure&&evidenceErrors.length===0&&cleanup.storage_stopped&&cleanup.postgres_stopped&&cleanup.image_detached&&cleanup.fixture_removed;
    try{save('cleanup.json',{...cleanup,passed:success,interrupted,failure:failure??null,evidence_errors:evidenceErrors,scope:'Only this newly created image, postmaster and Storage process; existing clusters and volumes untouched'})}
    catch(e){evidenceErrors.push(`cleanup.json: ${scrub(e.message)}`);success=false}
    console.log(JSON.stringify({passed:success,evidence,failure:failure??null,evidence_errors:evidenceErrors,cleanup}));if(!success)process.exitCode=1;
  }else{console.error(failure??'Fixture setup failed before evidence directory');process.exitCode=1}
}
