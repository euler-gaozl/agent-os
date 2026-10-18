// Local browser regression fixture: no database, credentials, model or network
// calls. A responses arrive 12 seconds after B. Serves the actual built Console.
import http from 'node:http';
import {readFile} from 'node:fs/promises';
import {resolve, extname} from 'node:path';
import {fileURLToPath} from 'node:url';
const root = fileURLToPath(new URL('../web/dist/', import.meta.url));
let skillRevision = 1;
const resource = (kind, id, summary = false) => ({kind,id,revision:kind === 'skill' ? skillRevision : 1,summary,spec:{
  name:`Fixture ${id.toUpperCase()}`,prompt:`Prompt for ${id.toUpperCase()} only`,content:`Instructions for ${id.toUpperCase()}`,
  engine:'local',description:'Isolated UI regression fixture',publication:{enabled:false},
}});
const server = http.createServer(async (req,res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  const send = (value, delay=0) => setTimeout(()=>{if(!res.destroyed){res.writeHead(200,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(value));}},delay);
  const slow = id => id === 'a' ? 12000 : 20;
  if (url.pathname === '/api/catalog') {
    const kind = url.searchParams.get('kind');
    return send({items: ['agent','knowledge'].includes(kind) ? ['a','b'].map(id=>resource(kind,id,true)) : kind === 'skill' ? [resource(kind,'package',true)] : [],next_cursor:'',services:{registry:true,toolhub:true}});
  }
  if (url.pathname === '/api/runs') return send([]);
  if (url.pathname === '/api/resources' && req.method === 'POST') {
    let body=''; for await (const chunk of req) body += chunk;
    const saved=JSON.parse(body);
    return send({...saved,revision:2},12000);
  }
  if (url.pathname === '/api/status') return send({instances:[]});
  const detail = url.pathname.match(/^\/api\/resources\/(agent|knowledge)\/([ab])\/1$/);
  if (detail) return send(resource(detail[1],detail[2]),detail[1] === 'agent' ? slow(detail[2]) : 20);
  if (url.pathname === '/api/knowledge/files') {
    const id = url.searchParams.get('id');
    return send([{id:`file-${id}`,name:`${id.toUpperCase()}-only.txt`,document_id:id.repeat(32),artifact_hash:id.repeat(64),status:'ready'}],slow(id));
  }
  if (url.pathname === '/api/knowledge/query') {
    let body=''; for await (const chunk of req) body += chunk;
    const id = JSON.parse(body).knowledge.id;
    return send({hits:[{title:`Result ${id.toUpperCase()}`,content:`Evidence belongs to ${id.toUpperCase()} only`,source:`fixture:${id}`}]},slow(id));
  }
  const asset = url.pathname.match(/^\/api\/toolhub\/assets\/skill\/package\/(\d+)(.*)$/);
  if (asset) {
    const revision = +asset[1], suffix = asset[2];
    if (!suffix) return send({...resource('skill','package'),revision,enabled:false,health:'healthy',report:{findings:[]}});
    if (suffix === '/audit') return send([]);
    if (suffix === '/files') return send(['a','b'].map(id=>({path:`${id}.md`,hash:id.repeat(64)})));
    if (suffix === '/file') { const id=url.searchParams.get('path').slice(0,1); return send({content:`File ${id.toUpperCase()} · version ${revision}`,next_offset:20,has_more:false},slow(id)); }
    // Test-only button uses the real UI's recheck action to make a new catalog
    // version appear. The subsequent catalog poll must close the old review.
    if (suffix === '/check') { skillRevision++; return send({}); }
    if (suffix === '/activation') {res.writeHead(409);return res.end('{"error":"Fixture never enables resources"}');}
  }
  if (url.pathname.startsWith('/api/')) {res.writeHead(404);return res.end('{"error":"Unsupported fixture operation"}');}
  const relative = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
  const path = resolve(root,relative);
  if (!path.startsWith(resolve(root) + '/') && !path.startsWith(resolve(root) + '\\')) {res.writeHead(403);return res.end();}
  try { const body=await readFile(path);res.writeHead(200,{'Content-Type':{'.html':'text/html','.js':'text/javascript','.css':'text/css'}[extname(path)]||'application/octet-stream','Cache-Control':'no-store'});res.end(body); }
  catch {res.writeHead(404);res.end();}
});
server.listen(8109,'127.0.0.1',()=>console.log('Isolated UI race fixture http://127.0.0.1:8109 (A=12s, B=20ms)'));
