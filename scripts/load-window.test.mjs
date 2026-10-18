import assert from 'node:assert/strict';
import test from 'node:test';
import {overlapDuration} from './lib/load-window.mjs';
test('mixed workload excludes idle gaps and clips read boundaries',()=>{
 assert.equal(overlapDuration([[0,3000],[2000,5000],[19000,22000]],1000,20000),5000);
});
test('late polling cannot extend short completed tasks',()=>{
 const durable=[[0,100],[200,300]],observedCompletion=20000;
 assert.equal(overlapDuration(durable,0,observedCompletion),200);
 assert.equal(overlapDuration(durable,400,observedCompletion),0);
});
test('missing or reversed event times cannot pass evidence checks',()=>{
 assert.throws(()=>overlapDuration([[0,NaN]],0,90000));
 assert.throws(()=>overlapDuration([[100,99]],0,90000));
});
