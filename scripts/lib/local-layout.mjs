// Local maintenance only. No configuration values are returned in diagnostics.
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

export async function getLocalLayout() {
  const projectRoot=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
  let pointer;
  try { pointer=(await fs.readFile(path.join(projectRoot,'.local/layout.path'),'utf8')).trim(); }
  catch(error) { if(error.code!=='ENOENT')throw Error('Cannot read local layout pointer.'); }
  if(!pointer)return {project_root:projectRoot,config_root:path.join(projectRoot,'.state'),evidence_root:path.join(projectRoot,'.state'),legacy_state_root:path.join(projectRoot,'.state')};
  let layout;
  try {layout=JSON.parse(await fs.readFile(pointer,'utf8'));} catch {throw Error('Cannot parse local platform layout.');}
  if(layout.format!==1||path.resolve(layout.project_root).toLowerCase()!==projectRoot.toLowerCase())throw Error('Local layout belongs to another checkout.');
  for(const key of ['config_root','state_root','legacy_state_root']) {
    if(layout[key]===undefined&&key==='legacy_state_root')continue;
    if(typeof layout[key]!=='string'||!path.isAbsolute(layout[key]))throw Error('Local layout requires absolute paths.');
    const relative=path.relative('D:\\workspace',layout[key]);
    if(!relative||relative==='..'||relative.startsWith('..'+path.sep)||path.isAbsolute(relative))throw Error('Local layout escapes the managed workspace.');
  }
  return {...layout,evidence_root:path.join(path.dirname(layout.state_root),'evidence'),legacy_state_root:layout.legacy_state_root||path.join(projectRoot,'.state')};
}

export async function readLocalConfig(role) {
  if(!/^[a-z-]+$/.test(role))throw Error('Invalid service role.');
  const layout=await getLocalLayout();
  try{return JSON.parse(await fs.readFile(path.join(layout.config_root,'services',role+'.json'),'utf8'));}
  catch{throw Error('Cannot read local service configuration: '+role);}
}
