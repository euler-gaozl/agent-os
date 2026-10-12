// Sum the union of durable task intervals clipped to the shared read window.
// CI containers and this client share the same host clock. Do not use observed
// polling completion times, nor count gaps between separate task intervals.
export function overlapDuration(intervals, start, end) {
 if(!Number.isFinite(start)||!Number.isFinite(end)||end<start)throw Error('Invalid read interval');
 const clipped=intervals.map(([a,b])=>{
  if(!Number.isFinite(a)||!Number.isFinite(b)||b<a)throw Error('Invalid durable execution interval');
  return [Math.max(a,start),Math.min(b,end)];
 }).filter(([a,b])=>b>a).sort((a,b)=>a[0]-b[0]);
 let total=0,left=null,right=null;
 for(const [a,b] of clipped){
  if(left===null){left=a;right=b}else if(a<=right){right=Math.max(right,b)}else{total+=right-left;left=a;right=b}
 }
 return total+(left===null?0:right-left);
}
