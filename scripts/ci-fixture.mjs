// Deterministic provider/MCP fixture. This is NOT a real model or research source.
import http from 'node:http';
const tool={name:'read',description:'Read controlled fixture',inputSchema:{type:'object',properties:{},additionalProperties:false}};
const telemetry=new Set();
http.createServer(async(req,res)=>{
 let text='';for await(const part of req){text+=part;if(text.length>2**20){res.writeHead(413).end();return}}
 const body=JSON.parse(text||'{}');res.setHeader('Content-Type','application/json');
 if(req.url==='/telemetry-receipts'){res.end(JSON.stringify({accepted_unique_spans:telemetry.size}));return}
 if(req.url==='/api/public/otel/v1/traces'){
  if(req.headers.authorization!=='Basic '+Buffer.from('ci-public:ci-secret').toString('base64')){res.writeHead(401).end('{}');return}
  const spans=body.resourceSpans?.flatMap(x=>x.scopeSpans?.flatMap(y=>y.spans??[])??[])??[];
  if(!spans.length||spans.some(s=>!/^\w{32}$/.test(s.traceId)||!/^\w{16}$/.test(s.spanId))){res.writeHead(400).end('{}');return}
  for(const span of spans)telemetry.add(span.traceId+':'+span.spanId);
  res.end('{}');return
 }
 if(req.url==='/mcp'){
  if(body.method==='notifications/initialized'){res.writeHead(202).end();return}
  const result=body.method==='initialize'?{protocolVersion:'2025-11-25'}:body.method==='tools/list'?{tools:[tool]}:{content:[{type:'text',text:'Fixture MCP evidence.'}]};
  res.end(JSON.stringify({jsonrpc:'2.0',id:body.id,result}));return
 }
 const tools=(body.messages||[]).filter(m=>m.role==='tool');let message={role:'assistant',content:'Controlled service contract test completed.'};
 const call=(name,args)=>({role:'assistant',content:'',tool_calls:[{id:'fixture-'+tools.length,type:'function',function:{name,arguments:JSON.stringify(args)}}]});
 if(tools.length===0)message=call('note_save',{kind:'evidence',title:'CI durable receipt',content:'Controlled fixture only.',source:'fixture://ci'});
 if(tools.length===1)message=call('kb_search',{kb_id:'ci-kb',query:'甲醇库存'});
 if(tools.length===2){const result=JSON.parse(tools[1].content);if(!result.hits?.[0]?.document_id)throw Error('Expected retrieved source');message=call('document_read',{id:result.hits[0].document_id,limit:100})}
 if(tools.length===3)message=call('mcp_fixture_read',{});
 await new Promise(resolve=>setTimeout(resolve,2500));
 res.end(JSON.stringify({id:'fixture',choices:[{index:0,message,finish_reason:message.tool_calls?'tool_calls':'stop'}],usage:{prompt_tokens:100,completion_tokens:40,total_tokens:140}}));
}).listen(8111,'0.0.0.0');
