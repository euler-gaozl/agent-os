import { useEffect, useRef, useState } from "react";
import {
  FileText,
  History,
  RefreshCw,
  Search,
  ShieldCheck,
} from "lucide-react";
import { api, date, Empty, Field, Modal, Spinner } from "./shared";
import "./notes.css";
import {
  pendingNote,
  retainNoteRequest,
  clearNoteRequest,
  isNoteRejection,
  type PendingNote,
} from "./note-pending";

type Lifecycle = {
  root_id: string;
  current_id: string | null;
  state: string;
  is_current: boolean;
  effective: boolean;
  expired: boolean;
  reason?: string;
};
type Note = {
  id: string;
  root_id?: string;
  title: string;
  kind: string;
  scope: string;
  source: string;
  content: string;
  metadata: Record<string, unknown>;
  valid_until?: string;
  supersedes?: string;
  state?: string;
  lifecycle: Lifecycle;
};
type Page<T> = { items: T[]; next_cursor: string };
const states: Record<string, string> = {
  active: "当前有效",
  expired: "已过期",
  retired: "已撤回",
  conflict: "版本冲突",
  superseded: "已被修订",
};
const kinds: Record<string, string> = {
  memory: "工作记忆",
  fact: "事实记录",
  evidence: "证据",
  knowledge: "知识",
};
const stateOf = (n: Note) =>
  n.state ||
  (n.lifecycle.state === "active" && !n.lifecycle.is_current
    ? "superseded"
    : n.lifecycle.state === "active" && n.lifecycle.expired
      ? "expired"
      : n.lifecycle.state);

export function Notes({ notify }: { notify: (s: string) => void }) {
  const [query, setQuery] = useState("");
  const [state, setState] = useState("");
  const [cursors, setCursors] = useState([""]);
  const [items, setItems] = useState<Note[]>([]);
  const [next, setNext] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [revision, setRevision] = useState(0);
  const [selected, setSelected] = useState<string>();
  const after = cursors[cursors.length - 1];
  useEffect(() => {
    let active = true;
    setLoading(true);
    setError("");
    setItems([]);
    setNext("");
    const timer = setTimeout(() => {
      void api<Page<Note>>(
        "/notes?" + new URLSearchParams({ q: query, state, after }),
      )
        .then((v) => {
          if (active) {
            setItems(v.items);
            setNext(v.next_cursor);
          }
        })
        .catch((e) => {
          if (active) setError(e.message);
        })
        .finally(() => {
          if (active) setLoading(false);
        });
    }, 180);
    return () => {
      active = false;
      clearTimeout(timer);
    };
  }, [query, state, after, revision]);
  return (
    <>
      <div className="info-banner">
        <ShieldCheck size={21} />
        <div>
          <b>有效资料与原始记录，分别保留</b>
          <p>
            修订会生成新版本；撤回和过期只影响有效检索。原文、修改理由和执行回执始终可回查。
          </p>
        </div>
      </div>
      <div className="section-toolbar note-toolbar">
        <div className="search-input">
          <Search size={16} />
          <input
            aria-label="搜索工作记忆"
            placeholder="搜索标题、正文或 Agent ID…"
            value={query}
            onChange={(e) => {
              setQuery(e.target.value);
              setCursors([""]);
            }}
          />
        </div>
        <select
          aria-label="筛选记忆状态"
          value={state}
          onChange={(e) => {
            setState(e.target.value);
            setCursors([""]);
          }}
        >
          <option value="">全部状态</option>
          {Object.entries(states)
            .filter(([k]) => k !== "superseded")
            .map(([k, v]) => (
              <option key={k} value={k}>
                {v}
              </option>
            ))}
        </select>
        <button className="button" onClick={() => setRevision((v) => v + 1)}>
          <RefreshCw size={15} />
          刷新记录
        </button>
      </div>
      {error && (
        <div className="inline-warning" role="alert">
          {error}
        </div>
      )}
      {loading ? (
        <div className="inline-empty">
          <Spinner /> 正在读取持久化记录…
        </div>
      ) : items.length ? (
        <div className="note-list">
          {items.map((n) => (
            <button
              className="note-card"
              key={n.root_id}
              onClick={() => setSelected(n.id)}
            >
              <div className="note-card-top">
                <span className="note-type">
                  <FileText size={16} />
                  {kinds[n.kind] || n.kind}
                </span>
                <span className={"note-state " + stateOf(n)}>
                  {states[stateOf(n)]}
                </span>
              </div>
              <h3>{n.title}</h3>
              <p>{n.content}</p>
              <div className="note-card-foot">
                <span>{n.scope || "全局共享"}</span>
                <span>
                  原文与版本 <History size={14} />
                </span>
              </div>
            </button>
          ))}
        </div>
      ) : (
        !error && (
          <Empty
            title="这里会保留 Agent 的工作记忆"
            detail="执行中的有出处记录会落在这里。可以按状态回看、修订或撤回已有资料。"
          />
        )
      )}
      <div className="note-pagination">
        <small>按记录 ID 分页，当前页 {items.length} 条</small>
        <div className="button-row">
          {cursors.length > 1 && (
            <button
              className="button"
              disabled={loading}
              onClick={() => setCursors((v) => v.slice(0, -1))}
            >
              上一页
            </button>
          )}
          {next && (
            <button
              className="button"
              disabled={loading}
              onClick={() => setCursors((v) => [...v, next])}
            >
              下一页
            </button>
          )}
        </div>
      </div>
      {selected && (
        <NoteDetail
          key={selected}
          id={selected}
          close={() => setSelected(undefined)}
          notify={notify}
          changed={() => setRevision((v) => v + 1)}
        />
      )}
    </>
  );
}

function NoteDetail({
  id,
  close,
  notify,
  changed,
}: {
  id: string;
  close: () => void;
  notify: (s: string) => void;
  changed: () => void;
}) {
  const [doc, setDoc] = useState<Note>();
  const [history, setHistory] = useState<any[]>([]),
    [historyNext, setHistoryNext] = useState("");
  const [audit, setAudit] = useState<any[]>([]),
    [auditNext, setAuditNext] = useState("");
  const [tab, setTab] = useState("original");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [edit, setEdit] = useState<"revise" | "retire">();
  const [draft, setDraft] = useState({
    title: "",
    content: "",
    source: "",
    metadata: "{}",
    valid_until: "",
    reason: "",
  });
  const [pending, setPending] = useState<PendingNote>();
  const restoredPending = useRef(false);
  const mounted = useRef(true),
    version = useRef(0);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      version.current++;
    };
  }, []);
  const read = async (documentID: string) => {
    const request = ++version.current;
    setBusy(true);
    setError("");
    try {
      const v = await api<Note>("/documents/" + encodeURIComponent(documentID));
      if (mounted.current && request === version.current) {
        setDoc(v);
        if (!restoredPending.current) {
          restoredPending.current = true;
          const saved = pendingNote(v.lifecycle.root_id);
          if (saved) {
            setPending(saved);
            setEdit(saved.kind as "revise" | "retire");
            setDraft({
              title: saved.body.title || v.title,
              content: saved.body.content || v.content,
              source: saved.body.source || v.source,
              metadata: JSON.stringify(saved.body.metadata || {}, null, 2),
              valid_until: saved.body.valid_until || "",
              reason: saved.body.reason,
            });
            setError(
              "已找回上次待确认的请求。请重试原请求，平台会返回原回执或执行这一次修改。",
            );
          }
        }
      }
    } catch (e) {
      if (mounted.current && request === version.current)
        setError((e as Error).message);
    } finally {
      if (mounted.current && request === version.current) setBusy(false);
    }
  };
  const loadHistory = async (after = "") => {
    setBusy(true);
    setError("");
    try {
      const v = await api<Page<any>>(
        "/notes/" +
          encodeURIComponent(id) +
          "/history?" +
          new URLSearchParams({ after }),
      );
      if (mounted.current) {
        setHistory((old) => (after ? [...old, ...v.items] : v.items));
        setHistoryNext(v.next_cursor);
      }
    } catch (e) {
      if (mounted.current) setError((e as Error).message);
    } finally {
      if (mounted.current) setBusy(false);
    }
  };
  const loadAudit = async (after = "") => {
    setBusy(true);
    setError("");
    try {
      const v = await api<Page<any>>(
        "/notes/" +
          encodeURIComponent(id) +
          "/audit?" +
          new URLSearchParams({ after }),
      );
      if (mounted.current) {
        setAudit((old) => (after ? [...old, ...v.items] : v.items));
        setAuditNext(v.next_cursor);
      }
    } catch (e) {
      if (mounted.current) setError((e as Error).message);
    } finally {
      if (mounted.current) setBusy(false);
    }
  };
  useEffect(() => {
    void read(id);
  }, [id]);
  const begin = (kind: "revise" | "retire") => {
    if (!doc) return;
    setDraft({
      title: doc.title,
      content: doc.content,
      source: doc.source,
      metadata: JSON.stringify(doc.metadata, null, 2),
      valid_until: doc.valid_until || "",
      reason: "",
    });
    setError("");
    setEdit(kind);
  };
  const submit = async () => {
    if (!doc || busy) return;
    setError("");
    let request = pending;
    try {
      if (!request) {
        if (!draft.reason.trim()) throw new Error("请写明本次修改的理由。");
        const body: any = {
          request_id: crypto.randomUUID(),
          expected_current_id: doc.id,
          reason: draft.reason,
        };
        if (edit === "revise") {
          const metadata = JSON.parse(draft.metadata);
          if (
            !metadata ||
            Array.isArray(metadata) ||
            typeof metadata !== "object"
          )
            throw new Error("附加信息必须是 JSON 对象。");
          Object.assign(body, {
            title: draft.title,
            content: draft.content,
            source: draft.source,
            metadata,
          });
          if (draft.valid_until.trim()) {
            const d = new Date(draft.valid_until);
            if (
              Number.isNaN(d.valueOf()) ||
              !/(Z|[+-]\d{2}:\d{2})$/.test(draft.valid_until.trim())
            )
              throw new Error(
                "请输入带时区的有效时间，例如 2027-01-01T00:00:00+08:00。",
              );
            body.valid_until = d.toISOString();
          }
        }
        request = { kind: edit!, body };
        try {
          retainNoteRequest(doc.lifecycle.root_id, request);
        } catch {
          setError(
            "无法保留请求编号，本次修改尚未发送。请检查浏览器会话存储。",
          );
          return;
        }
        setPending(request);
      }
      setBusy(true);
      const result = await api<any>("/notes/" + request.kind, request.body);
      clearNoteRequest(doc.lifecycle.root_id, request);
      if (!mounted.current) return;
      setPending(undefined);
      setEdit(undefined);
      setHistory([]);
      setAudit([]);
      setTab("original");
      changed();
      notify(
        request.kind === "revise"
          ? "新版本已保存，原文保持不变。"
          : "已撤回，历史资料仍保留。",
      );
      await read(result.document?.id || result.document_id);
    } catch (e) {
      if (!mounted.current) return;
      const status = (e as any).status;
      const rejected = isNoteRejection(e, request);
      if (rejected) {
        if (request) clearNoteRequest(doc.lifecycle.root_id, request);
        setPending(undefined);
      }
      setError(
        rejected && status === 409
          ? "资料已被其他任务修改或撤回。请取消编辑，刷新当前版本后再处理。"
          : request && !rejected
            ? "尚未取得确认结果。原请求已保留，请恢复访问后重试原请求，避免重复修改。"
            : (e as Error).message,
      );
    } finally {
      if (mounted.current) setBusy(false);
    }
  };
  const update = (key: keyof typeof draft, value: string) =>
    setDraft((v) => ({ ...v, [key]: value }));
  const editable =
    doc?.lifecycle.state === "active" &&
    doc.lifecycle.is_current &&
    !doc.scope.startsWith("knowledge:");
  return (
    <Modal
      title={
        edit
          ? edit === "revise"
            ? "修订工作记录"
            : "撤回工作记录"
          : "工作记录详情"
      }
      wide
      close={() => {
        if (!busy) close();
      }}
    >
      <div className="modal-body note-detail">
        {error && (
          <div className="inline-warning" role="alert">
            {error}
          </div>
        )}
        {busy && (
          <div className="note-loading" role="status">
            <Spinner /> 正在处理…
          </div>
        )}
        {doc && !edit && (
          <>
            <div className="note-detail-heading">
              <span className={"note-state " + stateOf(doc)}>
                {states[stateOf(doc)]}
                {!doc.lifecycle.is_current && doc.lifecycle.state !== "conflict"
                  ? " · 历史版本"
                  : ""}
              </span>
              <span>{doc.scope || "全局共享 · 模型只读"}</span>
            </div>
            <h2>{doc.title}</h2>
            <p className="note-source">来源：{doc.source}</p>
            <div className="tabs">
              {[
                ["original", "原文"],
                ["history", "所有版本"],
                ["audit", "修改记录"],
              ].map(([k, label]) => (
                <button
                  key={k}
                  disabled={busy}
                  className={tab === k ? "selected" : ""}
                  onClick={() => {
                    setTab(k);
                    if (k === "history") void loadHistory();
                    if (k === "audit") void loadAudit();
                  }}
                >
                  {label}
                </button>
              ))}
            </div>
            {tab === "original" && (
              <>
                <div className="note-original">{doc.content}</div>
                <dl className="note-meta">
                  <dt>记录 ID</dt>
                  <dd>{doc.id}</dd>
                  <dt>上一版本</dt>
                  <dd>{doc.supersedes || "首个版本"}</dd>
                  <dt>有效期至</dt>
                  <dd>{doc.valid_until ? date(doc.valid_until) : "未设置"}</dd>
                  {doc.lifecycle.reason && (
                    <>
                      <dt>撤回理由</dt>
                      <dd>{doc.lifecycle.reason}</dd>
                    </>
                  )}
                </dl>
                {Object.keys(doc.metadata || {}).length > 0 && (
                  <details>
                    <summary>附加信息</summary>
                    <pre>{JSON.stringify(doc.metadata, null, 2)}</pre>
                  </details>
                )}
              </>
            )}
            {tab === "history" && (
              <>
                <p className="note-help">
                  保留所有历史版本，按记录 ID 分页。版本分叉不会自动选取胜者。
                </p>
                <div className="note-history">
                  {history.map((v) => (
                    <button
                      className="note-version"
                      key={v.id}
                      disabled={busy}
                      onClick={() => {
                        setTab("original");
                        void read(v.id);
                      }}
                    >
                      <b>{v.title}</b>
                      <span>
                        {v.id === doc.lifecycle.current_id
                          ? "当前版本"
                          : "历史版本"}{" "}
                        · {date(v.created_at)}
                      </span>
                      <small>{v.id}</small>
                    </button>
                  ))}
                </div>
                {historyNext && (
                  <button
                    className="button"
                    disabled={busy}
                    onClick={() => void loadHistory(historyNext)}
                  >
                    载入后续版本
                  </button>
                )}
              </>
            )}
            {tab === "audit" && (
              <>
                <p className="note-help">
                  记录服务或 Agent 身份；早期资料没有事后补造的修改记录。
                </p>
                {audit.map((a) => (
                  <div className="note-audit" key={a.seq}>
                    <b>
                      {{ create: "新建", revise: "修订", retire: "撤回" }[
                        a.action as string
                      ] || a.action}
                    </b>
                    <p>{a.reason}</p>
                    <small>
                      {a.actor_kind === "agent" ? "Agent" : "服务"} ·{" "}
                      {a.actor_id} · {date(a.created_at)}
                    </small>
                    <small>
                      {a.operation_id || a.request_id || "旧管理接口写入"}
                    </small>
                  </div>
                ))}
                {auditNext && (
                  <button
                    className="button"
                    disabled={busy}
                    onClick={() => void loadAudit(auditNext)}
                  >
                    载入后续修改记录
                  </button>
                )}
              </>
            )}
            {doc.lifecycle.state === "conflict" && (
              <p className="inline-warning">
                存在历史分叉，当前没有唯一有效版本。请查阅各分支；平台不会自动合并或覆盖。
              </p>
            )}
            <div className="button-row note-actions">
              <button
                className="button"
                disabled={busy}
                onClick={() => void read(doc.id)}
              >
                刷新状态
              </button>
              {doc.lifecycle.current_id && !doc.lifecycle.is_current && (
                <button
                  className="button"
                  disabled={busy}
                  onClick={() => void read(doc.lifecycle.current_id!)}
                >
                  查看当前版本
                </button>
              )}
              {editable && (
                <>
                  <button
                    className="button"
                    disabled={busy}
                    onClick={() => begin("retire")}
                  >
                    撤回这条记录
                  </button>
                  <button
                    className="button primary"
                    disabled={busy}
                    onClick={() => begin("revise")}
                  >
                    创建修订版本
                  </button>
                </>
              )}
            </div>
          </>
        )}
        {doc && edit && (
          <form
            onSubmit={(e) => {
              e.preventDefault();
              void submit();
            }}
          >
            <p className="note-help">
              {edit === "revise"
                ? "修改后生成新版本，保留这份原文与引用关系。"
                : "撤回后不再进入有效检索，原文和所有版本继续保留。"}
            </p>
            <fieldset disabled={busy || !!pending} className="note-fields">
              {edit === "revise" && (
                <>
                  <Field label="标题">
                    <input
                      required
                      maxLength={300}
                      value={draft.title}
                      onChange={(e) => update("title", e.target.value)}
                    />
                  </Field>
                  <Field label="正文">
                    <textarea
                      required
                      maxLength={20000}
                      rows={8}
                      value={draft.content}
                      onChange={(e) => update("content", e.target.value)}
                    />
                  </Field>
                  <Field label="来源">
                    <input
                      required
                      maxLength={2000}
                      value={draft.source}
                      onChange={(e) => update("source", e.target.value)}
                    />
                  </Field>
                  <Field
                    label="有效期至"
                    hint="保留时区；留空表示新版本不设置过期时间。"
                  >
                    <input
                      placeholder="2027-01-01T00:00:00+08:00"
                      value={draft.valid_until}
                      onChange={(e) => update("valid_until", e.target.value)}
                    />
                  </Field>
                  <details>
                    <summary>附加信息</summary>
                    <Field label="JSON 对象">
                      <textarea
                        rows={4}
                        value={draft.metadata}
                        onChange={(e) => update("metadata", e.target.value)}
                      />
                    </Field>
                  </details>
                </>
              )}
              <Field label={edit === "revise" ? "修订理由" : "撤回理由"}>
                <textarea
                  required
                  maxLength={2000}
                  rows={3}
                  value={draft.reason}
                  onChange={(e) => update("reason", e.target.value)}
                />
              </Field>
            </fieldset>
            <div className="button-row note-actions">
              <button
                className="button"
                type="button"
                disabled={busy || !!pending}
                onClick={() => setEdit(undefined)}
              >
                取消编辑
              </button>
              <button className="button primary" type="submit" disabled={busy}>
                {busy ? (
                  <Spinner />
                ) : pending ? (
                  "重试原请求"
                ) : edit === "revise" ? (
                  "保存新版本"
                ) : (
                  "确认撤回"
                )}
              </button>
            </div>
          </form>
        )}
      </div>
    </Modal>
  );
}
