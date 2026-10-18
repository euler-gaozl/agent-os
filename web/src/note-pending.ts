// A tab refresh or closing the detail panel must not discard an uncertain
// mutation's idempotency key. This is a pending request, not the source of truth.
export type PendingNote = { kind: string; body: Record<string, any> };
const key = (root: string) => "agentos-note-pending:" + root;
export function pendingNote(root: string): PendingNote | undefined {
  const raw = sessionStorage.getItem(key(root));
  if (!raw) return undefined;
  const v = JSON.parse(raw);
  if (
    !v ||
    !["revise", "retire"].includes(v.kind) ||
    typeof v.body?.request_id !== "string" ||
    typeof v.body?.expected_current_id !== "string"
  )
    throw new Error("待确认请求格式异常，请保留浏览器会话并检查修改记录。");
  return v;
}
export function retainNoteRequest(root: string, request: PendingNote) {
  sessionStorage.setItem(key(root), JSON.stringify(request));
}
export function clearNoteRequest(root: string, request: PendingNote) {
  if (pendingNote(root)?.body.request_id === request.body.request_id)
    sessionStorage.removeItem(key(root));
}
// Only the Runtime mutation handler, after checking its receipt, can reject
// this exact request definitively. HTTP status alone may come from a gateway.
export function isNoteRejection(error: unknown, request?: PendingNote) {
  return (
    !!request &&
    (error as any)?.noteRejectedRequestId === request.body.request_id
  );
}
