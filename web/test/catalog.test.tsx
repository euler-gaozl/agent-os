import assert from 'node:assert/strict';
import test from 'node:test';
import {api,resourceDetail,type Resource} from '../src/shared';

test('editing a catalog row first loads the exact complete revision',async(t)=>{
  const full:Resource={kind:'agent',id:'long-agent',revision:7,spec:{name:'long agent',prompt:'HEAD '+ 'x'.repeat(90000)+' TAIL',constraints:['retained rule'],skills:[{id:'evidence',revision:2}],extension:{nested:'preserved'}}};
  const summary:Resource={...full,summary:true,spec:{name:'long agent',prompt:'HEAD'}};
  Object.defineProperty(globalThis,'sessionStorage',{configurable:true,value:{getItem:()=>null}});
  t.after(()=>{delete (globalThis as any).sessionStorage});
  const fetchMock=t.mock.method(globalThis,'fetch',async(input)=>{
    assert.equal(input,'/api/resources/agent/long-agent/7');
    return new Response(JSON.stringify(full),{headers:{'Content-Type':'application/json'}});
  });
  assert.deepEqual(await resourceDetail(summary),full);
  assert.equal(fetchMock.mock.callCount(),1);
  await assert.rejects(()=>api('/resources',summary),/摘要不能/);
  assert.equal(fetchMock.mock.callCount(),1,'summary write reached the network');
});

test('editor does not accept another revision or a failed detail request',async(t)=>{
  Object.defineProperty(globalThis,'sessionStorage',{configurable:true,value:{getItem:()=>null}});t.after(()=>{delete (globalThis as any).sessionStorage});
  const summary:Resource={kind:'skill',id:'method',revision:2,spec:{},summary:true};
  const mock=t.mock.method(globalThis,'fetch',async(input)=>{assert.equal(input,'/api/toolhub/assets/skill/method/2');return new Response(JSON.stringify({...summary,summary:false,revision:3}))});
  await assert.rejects(()=>resourceDetail(summary),/版本不匹配/);
  mock.mock.mockImplementation(async()=>new Response(JSON.stringify({error:'offline'}),{status:503}));
  await assert.rejects(()=>resourceDetail(summary),/offline/);
});
