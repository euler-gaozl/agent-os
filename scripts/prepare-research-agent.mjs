// Offline candidate preparation only. Never calls Registry, Runtime or a provider.
import fs from 'node:fs/promises';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';

const policy = 'research-completion-plan-v1';
const marker = `研究请求安排（${policy}）`;
const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');

export function prepareResearchAgent(resource) {
  if (resource?.kind !== 'agent' || typeof resource.id !== 'string' || !/^[a-zA-Z0-9_-]{1,128}$/.test(resource.id) ||
      !Number.isSafeInteger(resource.revision) || resource.revision < 1 ||
      !resource.spec || typeof resource.spec !== 'object' || Array.isArray(resource.spec))
    throw Error('An explicitly selected, revisioned Agent resource is required; seed packs and runs are not revisions');
  const spec = structuredClone(resource.spec);
  if (!Number.isSafeInteger(spec.max_steps) || spec.max_steps < 1 || spec.max_steps > 100 ||
      !Number.isSafeInteger(spec.max_model_attempts) || spec.max_model_attempts < 1 || spec.max_model_attempts > 500)
    throw Error('Both effective max_steps and max_model_attempts must be explicit positive limits');
  if (spec.max_children !== 0 || (spec.child_agents != null &&
      (!Array.isArray(spec.child_agents) || spec.child_agents.length !== 0)))
    throw Error('This plan covers a root Agent without children; family sharing needs a separate allocation');
  for (const field of ['prompts', 'skills', 'connectors', 'knowledge']) {
    if (spec[field] != null && (!Array.isArray(spec[field]) || spec[field].some(ref =>
      !ref || typeof ref.id !== 'string' || !/^[a-zA-Z0-9_-]{1,128}$/.test(ref.id) ||
      !Number.isSafeInteger(ref.revision) || ref.revision < 1)))
      throw Error('All resource bindings must have exact IDs and revisions: ' + field);
  }
  if (!Array.isArray(spec.skills) || !spec.skills.some(ref => ref.id === 'china-futures-research' &&
      Number.isSafeInteger(ref.revision) && ref.revision > 0))
    throw Error('An exact china-futures-research Skill revision must already be bound');
  if (spec.constraints != null && (!Array.isArray(spec.constraints) ||
      spec.constraints.some(value => typeof value !== 'string')))
    throw Error('Agent constraints must be strings');
  if (spec.constraints?.some(value => value.includes(marker)))
    throw Error('An existing completion plan must be reviewed explicitly, not stacked or silently replaced');

  // One generation can request many tools. Compact and retries consume model
  // capacity too; this static guidance does not observe their runtime counters.
  const capacity = Math.min(spec.max_steps, spec.max_model_attempts);
  const overhead = 2;
  const completion = 4; // first check, targeted source review, last check, final
  const reading = capacity - overhead - completion;
  if (reading < 1) throw Error('Insufficient existing budget for reading, completion and recovery allowance');
  const stages = {reading_through: reading, first_check_by: reading + 1,
    targeted_review_by: reading + 2, last_check_by: reading + 3, final_by: reading + 4};
  const instruction = `${marker}：本候选固定 max_steps=${spec.max_steps}、max_model_attempts=${spec.max_model_attempts}，不增加额度。普通生成请求按至多 ${stages.final_by} 轮安排，另留 ${overhead} 次给 Compact 或重试；这不是运行时剩余额度查询或完成保证。一次回复里的多个工具调用属于同一轮，工具回执数不等于模型请求数，Compact 和实际重试也会消耗额度。
第 1–${reading} 轮只围绕核心问题定位和回读资料；按问题记录已取得证据、完整 document_id、已读区间、日期/样本依据及具体缺口，保留在可用的工作状态中，不能只留在临时总结里。已知独立文档/分页成批读取，复用本任务已有回执，不重复搜索已知来源，不为读完导航/推荐/页脚消耗轮次；涉及关键正文或冲突的未知后页仍须核对。
最迟第 ${stages.first_check_by} 轮形成覆盖全部核心问题的完整草稿并调用已绑定的 check_research_draft_v2（含本任务 as_of），不能仍停在广泛资料浏览。第 ${stages.targeted_review_by} 轮仅为反馈指出的具体来源问题定向回读，可批量，不重新展开漫无边际的检索。最迟第 ${stages.last_check_by} 轮按反馈修订并作最后一次完整送检；最多两次检查，不必为了用满次数重复送检未改草稿。最迟第 ${stages.final_by} 轮输出完整结果；已送检时须逐字输出最后送检的完整 draft，不能在同轮再调用工具后期待下一次模型答复。已有充分证据和可交付草稿时提前结束。
未绑定检查工具时明确保留“草稿检查未执行”，不能声称已通过；无法取得的具体资料、无法解决的反馈和不成立的比较必须保留，不能编造原文、删核心问题或改写引文换取通过。最后送检后不再改报数、日期、引用或解读；有剩余待核项仍如实交付，最终输出不等于研究质量验收通过。发生 Compact/失败或无法确认计数时提前进入收尾；两次余量不足时仍可能失败，不自行重启任务、加额度或声称恢复成功。`;
  spec.constraints = [...(spec.constraints ?? []), instruction];
  const candidate = {kind: 'agent', id: resource.id, spec};
  return {candidate, plan: {format: 1, policy, status: 'offline_candidate_not_registered_or_validated',
    source: {kind: 'agent', id: resource.id, revision: resource.revision,
      spec_sha256: hash(resource.spec)}, candidate_spec_sha256: hash(spec),
    max_steps: spec.max_steps, max_model_attempts: spec.max_model_attempts,
    planning_capacity: capacity, overhead_allowance: overhead, stages,
    enforcement: 'Static instruction only; DSH still owns the loop. No dynamic counter or new engine protocol.',
    registration: 'Register as a new Agent revision, verify returned spec and unchanged exact bindings, then explicitly select that new revision for a new task. Never apply to an existing run.'}};
}

export async function writeResearchAgentCandidate(resource, output) {
  const result = prepareResearchAgent(resource);
  await fs.mkdir(output); // Refuse overwrite, including reruns and existing symlinks.
  await fs.writeFile(path.join(output, 'agent.json'), JSON.stringify(result.candidate, null, 2) + '\n', {flag: 'wx'});
  await fs.writeFile(path.join(output, 'plan.json'), JSON.stringify(result.plan, null, 2) + '\n', {flag: 'wx'});
  return result.plan;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    if (process.argv.length !== 4) throw Error('Usage: node prepare-research-agent.mjs <exact-agent-resource.json> <new-directory>');
    if ((await fs.stat(process.argv[2])).size > 2 * 1024 * 1024) throw Error('Agent resource exceeds 2 MiB');
    const resource = JSON.parse(await fs.readFile(process.argv[2], 'utf8'));
    const output = path.resolve(process.argv[3]);
    const plan = await writeResearchAgentCandidate(resource, output);
    console.log(JSON.stringify({output, source: plan.source, status: plan.status}));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
