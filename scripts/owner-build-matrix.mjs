import fs from 'node:fs';
import {fileURLToPath} from 'node:url';
const names=['control','registry','runtime','worker','toolhub','knowledge','indexer','storage','sandbox','futures','telemetry','sources'];
export function matrix(lock){
 if(lock?.format!==1||!lock.services||Object.keys(lock.services).length!==names.length)throw Error('Complete owner source lock required');
 return {include:names.map(role=>{
  const entry=lock.services[role],repository=role==='control'?'agent-os-console':'agent-os-'+role;
  if(entry?.repository!==repository||!/^[a-f0-9]{40}$/.test(entry.commit??''))throw Error('Unexpected owner source mapping');
  return {role,repository,commit:entry.commit,secret:'AGENTOS_OWNER_READ_'+role.toUpperCase()};
 })};
}
if(process.argv[1]&&fileURLToPath(import.meta.url)===fs.realpathSync(process.argv[1])){
 const lock=JSON.parse(fs.readFileSync(new URL('../deploy/service-sources.json',import.meta.url),'utf8'));
 console.log(JSON.stringify(matrix(lock)));
}
