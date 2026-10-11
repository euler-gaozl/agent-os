import fs from 'node:fs';
const file=process.argv[2];if(!file)throw Error('Pass service-smoke.json');
const evidence=JSON.parse(fs.readFileSync(file,'utf8'));
function bytes(value){const m=value.trim().match(/^([\d.]+)(B|KiB|MiB|GiB|kB|MB|GB)$/);if(!m)throw Error('Unknown memory unit');return Number(m[1])*({B:1,KiB:1024,MiB:1024**2,GiB:1024**3,kB:1000,MB:1000**2,GB:1000**3}[m[2]])}
const samples=new Map();
for(const r of evidence.resources){if(!r.Name.startsWith('agent-os-')||r.Name.startsWith('agent-os-fixture-')||r.Name.startsWith('agent-os-migrate-'))continue;const time=r.time.slice(0,19);let sample=samples.get(time);if(!sample){sample={bytes:0,limit:0,cpu:0,containers:0};samples.set(time,sample)};const [used,limit]=r.MemUsage.split('/');sample.bytes+=bytes(used);sample.limit+=bytes(limit);sample.cpu+=parseFloat(r.CPUPerc);sample.containers++}
const values=[...samples.values()];
console.log(JSON.stringify({environment:evidence.platform,model:evidence.model,completed_checks:evidence.checks,sampled_points:values.length,peak_sampled_platform_mib:Math.round(Math.max(...values.map(x=>x.bytes))/1024**2*10)/10,configured_memory_limits_mib:Math.round(Math.max(...values.map(x=>x.limit))/1024**2),peak_sampled_cpu_percent:Math.round(Math.max(...values.map(x=>x.cpu))*10)/10,note:'Small controlled task, including PostgreSQL and DSH; excludes fixture. Sampling is not continuous peak or million-document capacity acceptance.'},null,2));
