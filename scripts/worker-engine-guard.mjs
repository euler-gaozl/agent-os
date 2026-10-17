// Image metadata is an operator-owned release contract, not untrusted model input.
// Pre-contract images are known to support only these two historical engines.
const historical = ['legacy-go', 'dsh-0.2.0-rc.2'];
export function workerEngines(labels) {
  const raw = labels?.['org.agentos.worker-engines'];
  if (raw === undefined) return historical;
  const engines = JSON.parse(raw);
  if (!Array.isArray(engines) || engines.length === 0 || engines.length > 16 || engines.some(x => typeof x !== 'string' || !/^[a-zA-Z0-9._-]{1,100}$/.test(x))) throw Error('invalid Worker engine compatibility label');
  return engines;
}
export function requireWorkerCompatibility(previous, next) {
  const supported = new Set(workerEngines(next));
  if (workerEngines(previous).some(x => !supported.has(x))) throw Error('Worker downgrade removes a supported execution engine; drain or migrate retained tasks and follow the execution protocol migration procedure');
}
export function requireToolCompatibility(previous, next) {
  const supported = labels => {
    const raw = labels?.['org.agentos.builtin-tools'];
    if (raw === undefined) return ['knowledge_search', 'note_save', 'artifact_read', 'spawn_agent', 'sandbox_exec', 'document_read'];
    const names = JSON.parse(raw);
    if (!Array.isArray(names) || names.length === 0 || names.length > 128 || names.some(x => typeof x !== 'string' || !/^[a-zA-Z0-9_-]{1,128}$/.test(x))) throw Error('invalid builtin compatibility label');
    return names;
  };
  const available = new Set(supported(next));
  if (supported(previous).some(x => !available.has(x))) throw Error('Service downgrade removes a supported builtin; stop submissions and migrate all dependent Agent versions and resumable tasks first');
}
