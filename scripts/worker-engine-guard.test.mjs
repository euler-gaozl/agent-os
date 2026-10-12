import {test} from 'node:test';
import assert from 'node:assert/strict';
import {workerEngines, requireWorkerCompatibility, requireToolCompatibility} from './worker-engine-guard.mjs';
const current = {'org.agentos.worker-engines': JSON.stringify(['legacy-go', 'dsh-0.2.0-rc.2', 'dsh-0.2.0-rc.2-evidence-v1'])};
test('Worker upgrades preserve historical engines; rollback cannot silently strand evidence runs', () => {
  assert.doesNotThrow(() => requireWorkerCompatibility(null, current));
  assert.doesNotThrow(() => requireWorkerCompatibility(current, current));
  assert.throws(() => requireWorkerCompatibility(current, null), /downgrade/);
  assert.throws(() => workerEngines({'org.agentos.worker-engines': '[]'}), /invalid/);
  assert.throws(() => workerEngines({'org.agentos.worker-engines': 'null'}), /invalid/);
});
test('Runtime and ToolHub cannot lose tools bound to persisted run snapshots', () => {
  const tools = {'org.agentos.builtin-tools': JSON.stringify(['knowledge_search', 'note_save', 'artifact_read', 'spawn_agent', 'sandbox_exec', 'document_read', 'run_recall'])};
  assert.doesNotThrow(() => requireToolCompatibility(null, tools));
  assert.doesNotThrow(() => requireToolCompatibility(tools, tools));
  assert.throws(() => requireToolCompatibility(tools, null), /supported builtin/);
  assert.throws(() => requireToolCompatibility(tools, {'org.agentos.builtin-tools': 'null'}), /invalid/);
});
