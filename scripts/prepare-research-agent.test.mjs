import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {prepareResearchAgent, writeResearchAgentCandidate} from './prepare-research-agent.mjs';

const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const fixture = () => ({kind: 'agent', id: 'synthetic-supply', revision: 3, spec: {
  name: 'Synthetic fixture; not an original Windows Agent', prompt: 'Keep evidence boundaries.',
  skills: [{id: 'china-futures-research', revision: 2}],
  connectors: [{id: 'synthetic-checker', revision: 1}],
  knowledge: [{id: 'synthetic-library', revision: 2}], tools: ['document_read'],
  model: {model: 'synthetic-only', key_env: 'SYNTHETIC_KEY_REFERENCE', limits: {fixture: true}},
  max_steps: 12, max_model_attempts: 12, model_token_budget: 0,
  max_children: 0, child_agents: [], constraints: ['Preserve facts and exact quotes.'],
  publication: {enabled: true, app: 'futures'},
}});

test('exact baseline and bindings survive candidate creation without changing budgets or old data', () => {
  const original = fixture(), before = structuredClone(original);
  const {candidate, plan} = prepareResearchAgent(original);
  assert.deepEqual(original, before);
  assert.equal('revision' in candidate, false); // Registry must allocate a new revision.
  assert.deepEqual({...candidate.spec, constraints: before.spec.constraints}, before.spec);
  assert.equal(candidate.spec.constraints.length, before.spec.constraints.length + 1);
  assert.deepEqual(plan.source, {kind: 'agent', id: original.id, revision: 3, spec_sha256: hash(before.spec)});
  assert.equal(plan.candidate_spec_sha256, hash(candidate.spec));
  assert.deepEqual(plan.stages, {reading_through: 6, first_check_by: 7, targeted_review_by: 8, last_check_by: 9, final_by: 10});
  assert.equal(plan.stages.final_by + plan.overhead_allowance, 12);
  candidate.spec.skills[0].revision = 999;
  assert.equal(original.spec.skills[0].revision, 2);
});

test('the tighter existing limit determines the schedule; attempts and steps remain distinct', () => {
  for (const [steps, attempts, capacity] of [[12, 40, 12], [20, 12, 12], [18, 40, 18], [7, 7, 7]]) {
    const input = fixture(); input.spec.max_steps = steps; input.spec.max_model_attempts = attempts;
    const {candidate, plan} = prepareResearchAgent(input);
    assert.equal(plan.planning_capacity, capacity);
    assert.equal(plan.stages.final_by + plan.overhead_allowance, capacity);
    assert.equal(candidate.spec.max_steps, steps);
    assert.equal(candidate.spec.max_model_attempts, attempts);
  }
});

test('Go nil slices remain valid empty bindings and are preserved in the candidate', () => {
  const input = fixture();
  for (const key of ['prompts', 'connectors', 'knowledge', 'child_agents', 'constraints']) input.spec[key] = null;
  const before = structuredClone(input);
  const {candidate} = prepareResearchAgent(input);
  assert.deepEqual(input, before);
  for (const key of ['prompts', 'connectors', 'knowledge', 'child_agents']) assert.equal(candidate.spec[key], null);
  assert.equal(candidate.spec.constraints.length, 1);
});

test('reject ambiguous baselines, implicit limits, family allocations and previously planned Agents', () => {
  for (const mutate of [
    input => delete input.revision, input => input.revision = 0, input => input.kind = 'run',
    input => delete input.id, input => input.id = 123,
    input => delete input.spec.max_steps, input => input.spec.max_model_attempts = 0,
    input => input.spec.max_steps = 6, input => input.spec.max_steps = 101,
    input => input.spec.max_model_attempts = 12.5,
    input => input.spec.max_children = 1,
    input => input.spec.child_agents = [{id: 'child', revision: 1}],
    input => input.spec.skills[0].revision = 0,
    input => input.spec.connectors[0].revision = 'latest',
    input => input.spec.knowledge[0].revision = 0,
    input => input.spec.constraints = [42],
  ]) {
    const input = fixture(); mutate(input);
    assert.throws(() => prepareResearchAgent(input));
  }
  const planned = prepareResearchAgent(fixture()).candidate;
  assert.throws(() => prepareResearchAgent({...planned, revision: 4}), /existing completion plan/);
});

test('file output is a new unregistered candidate and refuses overwrite or invalid input before writes', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'research-agent-fixture-'));
  const output = path.join(root, 'candidate');
  await writeResearchAgentCandidate(fixture(), output);
  const candidate = JSON.parse(await fs.readFile(path.join(output, 'agent.json'), 'utf8'));
  const plan = JSON.parse(await fs.readFile(path.join(output, 'plan.json'), 'utf8'));
  assert.equal('revision' in candidate, false);
  assert.equal(plan.candidate_spec_sha256, hash(candidate.spec));
  await assert.rejects(writeResearchAgentCandidate(fixture(), output), {code: 'EEXIST'});
  const rejected = path.join(root, 'rejected');
  await assert.rejects(writeResearchAgentCandidate({...fixture(), revision: undefined}, rejected));
  await assert.rejects(fs.stat(rejected), {code: 'ENOENT'});
  // Controlled fixture output stays under the caller's temporary directory.
});
