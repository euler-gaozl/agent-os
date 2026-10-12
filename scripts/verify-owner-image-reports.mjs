import fs from 'node:fs';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {matrix} from './owner-build-matrix.mjs';
const lock=JSON.parse(fs.readFileSync(new URL('../deploy/service-sources.json',import.meta.url),'utf8'));
const expected=matrix(lock).include;
const root=path.resolve(process.argv[2]??'.state/owner-reports');
const integration=execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim();
const directories=fs.readdirSync(root);
if(directories.length!==expected.length)throw Error('Exactly twelve owner reports are required');
for(const entry of expected){
 const report=JSON.parse(fs.readFileSync(path.join(root,'owner-image-'+entry.role,'result.json'),'utf8'));
 const actual=report.services?.[0];
 if(report.passed!==true||report.integration_commit!==integration||report.services.length!==1||actual.role!==entry.role||actual.repository!==entry.repository||actual.commit!==entry.commit||!/^sha256:[a-f0-9]{64}$/.test(actual.image)||actual.executables_checked!==true||!Array.isArray(actual.binary_checks)||actual.binary_checks.length<2)throw Error('Missing, failed or mismatched owner report: '+entry.role);
}
console.log('All twelve independent owner image builds and binary checks passed for the selected integration commit. This is not a live service or migration test.');
