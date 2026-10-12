import assert from 'node:assert/strict';
import test from 'node:test';
import {api} from '../src/shared';
import {pendingNote,retainNoteRequest,clearNoteRequest,isNoteRejection} from '../src/note-pending';

test('lost reply followed by gateway refusal retains the same request until a confirmed result', async(t)=>{
  const storage = new Map<string,string>();
  Object.defineProperty(globalThis,'sessionStorage',{configurable:true,value:{
    getItem:(k:string)=>storage.get(k)??null,
    setItem:(k:string,v:string)=>storage.set(k,v),
    removeItem:(k:string)=>storage.delete(k),
  }});
  t.after(()=>{delete (globalThis as any).sessionStorage});
  const original={kind:'revise',body:{request_id:'committed-but-reply-lost',expected_current_id:'original-document',reason:'source correction'}};
  retainNoteRequest('root',original);
  let reply = new Response('unavailable',{status:503});
  t.mock.method(globalThis,'fetch',async(_input,options)=>{
    assert.deepEqual(JSON.parse(options?.body as string),original.body);
    return reply;
  });
  for(const status of [401,403,404,400,409,429,503]){
    reply=new Response(JSON.stringify({error:'gateway refusal'}),{status});
    const restored=pendingNote('root');
    assert.deepEqual(restored,original);
    try { await api('/notes/revise',restored!.body); assert.fail('request should fail') }
    catch(e) { if(isNoteRejection(e,restored)) clearNoteRequest('root',restored!); }
    assert.deepEqual(pendingNote('root'),original,'HTTP code alone cleared an uncertain result');
  }
  assert.equal(isNoteRejection({noteRejectedRequestId:'other'},original),false);
  reply=new Response(JSON.stringify({error:'stale current version',note_rejected_request_id:original.body.request_id}),{status:409});
  try { await api('/notes/revise',original.body); assert.fail('request should fail') }
  catch(e) { assert.equal(isNoteRejection(e,original),true); clearNoteRequest('root',original); }
  assert.equal(pendingNote('root'),undefined);
});
