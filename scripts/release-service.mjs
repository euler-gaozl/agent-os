// No model credentials on the command line. Only this unit's Docker Compose
// project is changed; deployment state contains paths and hashes, not secrets.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {parseArgs} from 'node:util';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const {values,positionals}=parseArgs({allowPositionals:true,options:{project:{type:'string'},service:{type:'string'},image:{type:'string'},config:{type:'string'},network:{type:'string'},replicas:{type:'string'},publish:{type:'string'}}});
const action=positionals[0]??'status';
const roles=['control','toolhub','storage','sandbox','runtime','knowledge','registry','indexer','futures','worker','telemetry','sources'];
const project=values.project;
if(!/^agentos-[a-z][a-z0-9-]{0,47}$/.test(project??''))throw Error('--project must be an explicit agentos- deployment unit name');
if(!['deploy','rollback','status','stop'].includes(action))throw Error('action must be deploy, rollback, status or stop');
const directory=path.join(root,'.state','deployments',project), statePath=path.join(directory,'release.json');
fs.mkdirSync(directory,{recursive:true,mode:0o700});
const state=fs.existsSync(statePath)?JSON.parse(fs.readFileSync(statePath,'utf8')):{current:null,previous:null,history:[]};
function docker(args,env={},timeout=120000){return execFileSync('docker',args,{cwd:root,env:{...process.env,...env},encoding:'utf8',timeout,stdio:['pipe','pipe','pipe']}).trim()}
function digest(file){return createHash('sha256').update(fs.readFileSync(file)).digest('hex')}
function env(unit){return {SERVICE_IMAGE:unit.image,SERVICE_NAME:unit.service,SERVICE_CONFIG:unit.config,SERVICE_NETWORK:unit.network,SERVICE_PORT:String(unit.port),SERVICE_HOST_PORT:String(unit.publish),SERVICE_MEMORY:unit.service==='worker'?'384m':'128m',SERVICE_CPUS:unit.service==='worker'?'0.375':'0.10',SERVICE_HEALTH_KEY:unit.service==='control'?'ADMIN_TOKEN':unit.service==='futures'?'BUSINESS_TOKEN':'SERVICE_TOKEN'}}
function compose(unit,...args){return docker(['compose','-p',project,'-f',path.join(root,'deploy/service.compose.yaml'),...(unit.publish?['-f',path.join(root,'deploy/service.publish.yaml')]:[]),...args],env(unit))}
function validate(unit){
 if(!unit||!roles.includes(unit.service)||!/^sha256:[a-f0-9]{64}$/.test(unit.image))throw Error('invalid release record');
 if(digest(unit.config)!==unit.configHash)throw Error('configuration changed; restore its recorded version before deploying or rolling back');
 docker(['image','inspect',unit.image]);
 docker(['network','inspect',unit.network]);
}
function apply(unit){validate(unit);compose(unit,'up','-d','--no-build','--wait','--wait-timeout','90','--scale','app='+unit.replicas)}
function save(){fs.writeFileSync(statePath+'.new',JSON.stringify(state,null,2),{mode:0o600});fs.renameSync(statePath+'.new',statePath)}
if(action==='status'){
 console.log(JSON.stringify({project,current:state.current,previous:state.previous},null,2));
}else{
 const lock=path.join(directory,'release.lock');
 let handle;
 try{handle=fs.openSync(lock,'wx',0o600)}catch{throw Error('release unit is locked; inspect the existing operator process before removing release.lock')}
 fs.writeFileSync(handle,String(process.pid));
 try{
  if(action==='stop'){
   if(!state.current)throw Error('no recorded deployment');
   compose(state.current,'stop','app');
   state.history.push({action:'stop',at:new Date().toISOString()});save();
  }else{
   let next;
   if(action==='rollback'){
    if(!state.previous)throw Error('no prior release is recorded');
    next=state.previous;
   }else{
    const service=values.service;
    if(!roles.includes(service)||!values.image||!values.config||!values.network)throw Error('deploy requires --service, --image, --config and --network');
    const replicas=Number(values.replicas??1),publish=Number(values.publish??0);
    if(!Number.isInteger(replicas)||replicas<1||replicas>16)throw Error('replicas must be 1..16');
    if(!Number.isInteger(publish)||publish<0||publish>65535||(publish!==0&&publish<1024))throw Error('invalid loopback publication port');
    if(publish&&(!['control','futures'].includes(service)||replicas!==1))throw Error('only one gateway instance can publish a fixed loopback port; use a separate load balancer for replicas');
    const config=fs.realpathSync(values.config),parsed=JSON.parse(fs.readFileSync(config,'utf8'));
    if(!parsed.SERVICE_TOKEN||JSON.parse(parsed.SERVICE_PEERS??'{}')[service]!==createHash('sha256').update(parsed.SERVICE_TOKEN).digest('hex'))throw Error('configuration identity does not match selected service');
    if(!['control','futures'].includes(service)&&!parsed.DATABASE_URL)throw Error('service database configuration missing');
    if(['control','futures'].includes(service)&&parsed.DATABASE_URL)throw Error('gateway configuration must not contain database credentials');
    if(service==='control'&&!parsed.ADMIN_TOKEN||service==='futures'&&!parsed.BUSINESS_TOKEN)throw Error('gateway access token missing');
    if(state.current&&state.current.service!==service)throw Error('cannot replace a deployment unit with another service');
    const image=docker(['image','inspect','--format','{{.Id}}',values.image]);
    next={service,image,config,configHash:digest(config),network:values.network,port:8090+roles.indexOf(service),replicas,publish};
   }
   if(state.current)validate(state.current);
   // Refuse to take over another Compose application which happens to use
   // the same project name; initial deployment may contain no containers.
   const owned=docker(['ps','-aq','--filter','label=com.docker.compose.project='+project]);
   if(!state.current&&owned)throw Error('project already has containers but no managed release record');
   if(owned)for(const info of JSON.parse(docker(['inspect',...owned.split('\n')]))){if(info.Config.Labels['com.docker.compose.service']!=='app')throw Error('deployment unit contains an unmanaged service')}
   try{apply(next)}catch{
    let recovery='initial deployment failed';
    if(state.current){try{apply(state.current);recovery='previous release restored'}catch{recovery='automatic recovery failed; inspect this deployment unit'}}
    else{try{compose(next,'down')}catch{}}
    state.history.push({action:'failed',at:new Date().toISOString(),image:next.image,recovery});save();
    throw Error('service release failed; '+recovery);
   }
   state.previous=state.current;state.current=next;
   state.history.push({action,at:new Date().toISOString(),image:next.image});
   state.history=state.history.slice(-20);save();
   console.log(JSON.stringify({project,action,service:next.service,image:next.image,replicas:next.replicas}));
  }
 }finally{fs.closeSync(handle);fs.unlinkSync(lock)}
}
