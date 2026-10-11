import { useCallback, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  ArrowLeft,
  ArrowUp,
  ArrowUpRight,
  BookOpen,
  Check,
  ChevronDown,
  ChevronRight,
  Clock3,
  Compass,
  FileCheck2,
  FileText,
  Layers,
  Menu,
  Plus,
  Search,
  Sparkles,
  X,
} from "lucide-react";
import { api, Badge, date, Empty, Login, Spinner } from "./shared";
import "./futures.css";
type Action = {
  id: string;
  revision: number;
  name: string;
  description: string;
};
function Futures() {
  const [actions, setActions] = useState<Action[]>([]),
    [tasks, setTasks] = useState<any[]>([]),
    [action, setAction] = useState<Action | null>(null),
    [commodity, setCommodity] = useState("甲醇"),
    [period, setPeriod] = useState("最近三个月，并补充可比历史数据"),
    [question, setQuestion] = useState(""),
    [selected, setSelected] = useState(""),
    [result, setResult] = useState<any>(null),
    [error, setError] = useState(""),
    [connected, setConnected] = useState(false),
    [busy, setBusy] = useState(false),
    [ready, setReady] = useState<any>(null),
    [showScope, setShowScope] = useState(false),
    [mobileNav, setMobileNav] = useState(false),
    [notice, setNotice] = useState("");
  const key = useRef(crypto.randomUUID()),
    input = useRef<HTMLTextAreaElement>(null);
  const load = useCallback(async () => {
    const [a, t, r] = await Promise.all([
      api<Action[]>("/actions"),
      api<any[]>("/tasks"),
      api("/readiness"),
    ]);
    setActions(
      [...a].sort(
        (left, right) =>
          Number(right.id === "supply-inventory") -
          Number(left.id === "supply-inventory"),
      ),
    );
    setTasks(t);
    setReady(r);
    setConnected(true);
  }, []);
  useEffect(() => {
    void load().catch((e) => setError(e.message));
  }, [load]);
  useEffect(() => {
    const id = setInterval(() => void load().catch(() => {}), 6000);
    return () => clearInterval(id);
  }, [load]);
  useEffect(() => {
    if (!selected) {
      setResult(null);
      return;
    }
    let alive = true;
    const poll = async () => {
      try {
        const r = await api("/tasks/" + selected);
        if (alive) setResult(r);
      } catch (e) {
        if (alive) setNotice((e as Error).message);
      }
    };
    void poll();
    const id = setInterval(() => void poll(), 1800);
    return () => {
      alive = false;
      clearInterval(id);
    };
  }, [selected]);
  const choose = (a: Action) => {
    setAction(a);
    input.current?.focus();
  };
  const fresh = () => {
    setSelected("");
    setMobileNav(false);
    key.current = crypto.randomUUID();
  };
  const run = async () => {
    const a = action || actions[0];
    if (!a || !commodity.trim() || !question.trim()) return;
    setBusy(true);
    setNotice("");
    try {
      const r = await api(
        "/tasks",
        {
          action: { id: a.id, revision: a.revision },
          commodity,
          period,
          question,
        },
        key.current,
      );
      setSelected(r.id);
      key.current = crypto.randomUUID();
      await load();
    } catch (e) {
      setNotice((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  if (!connected)
    return error ? (
      <Login
        error={error}
        retry={() => void load().catch((e) => setError(e.message))}
      />
    ) : (
      <div className="loading-screen">
        <Spinner />
        打开研究工作台…
      </div>
    );
  return (
    <div className="research-shell">
      <aside className={"research-sidebar " + (mobileNav ? "open" : "")}>
        <a
          href="#"
          className="research-brand"
          onClick={(e) => {
            e.preventDefault();
            fresh();
          }}
        >
          <span className="research-mark">
            <Layers size={23} />
          </span>
          <b>
            研序<small>RESEARCH WORKSPACE</small>
          </b>
        </a>
        <button className="new-research" onClick={fresh}>
          <Plus size={17} />
          开始新研究<span>↗</span>
        </button>
        <div className="research-nav">
          <button className={!selected ? "active" : ""} onClick={fresh}>
            <Compass size={17} />
            研究工作台
          </button>
          <div className="history-label">
            最近研究 <span>{tasks.length}</span>
          </div>
          {tasks.length ? (
            <div className="task-history">
              {tasks.map((t) => (
                <button
                  key={t.id}
                  className={selected === t.id ? "selected" : ""}
                  onClick={() => {
                    setSelected(t.id);
                    setMobileNav(false);
                  }}
                >
                  <FileText size={15} />
                  <span>
                    {t.commodity} · 基本面研究
                    <small>{date(t.created_at)}</small>
                  </span>
                  <i className={"task-dot " + t.status} />
                </button>
              ))}
            </div>
          ) : (
            <p className="history-empty">你的研究记录会保存在这里。</p>
          )}
        </div>
        <div className="research-sidebar-footer">
          <div className="private-note">
            <BookOpen size={16} />
            <p>
              每一次研究，都有迹可循
              <small>原始资料与研究记录保存在你的工作区</small>
            </p>
          </div>
          <div className="research-profile">
            <span>G</span>
            <p>
              我的研究空间<small>个人工作区</small>
            </p>
            <ChevronDown size={14} />
          </div>
        </div>
      </aside>
      <div className="research-main">
        <header className="research-topbar">
          <button
            className="mobile-menu icon-button"
            aria-label="展开导航"
            onClick={() => setMobileNav(!mobileNav)}
          >
            <Menu size={19} />
          </button>
          <span>{selected ? "研究任务" : "中国期货 · 基本面研究"}</span>
          <div>
            <span className="workspace-label">
              <i />
              个人资料库
            </span>
            <button className="icon-button" aria-label="新研究" onClick={fresh}>
              <Plus size={17} />
            </button>
          </div>
        </header>
        {!selected ? (
          <main className="research-home">
            <div className="hero-orbit">
              <span>
                <Compass size={30} />
              </span>
              <i />
              <i />
              <i />
            </div>
            <div className="research-greeting">把资料留住，把问题弄清楚</div>
            <h1>今天，想研究什么？</h1>
            <p className="hero-subtitle">
              从真实数据出发，整理证据与变化。判断留给你。
            </p>
            <section className="research-composer">
              <textarea
                ref={input}
                aria-label="研究问题"
                value={question}
                onChange={(e) => {
                  setQuestion(e.target.value);
                  key.current = crypto.randomUUID();
                }}
                placeholder="例如：整理甲醇最近的供给和库存，核对港口与内地的数据变化…"
              />
              <div className="composer-bottom">
                <div className="composer-tags">
                  <button onClick={() => setShowScope(!showScope)}>
                    <span className="commodity-dot" />
                    {commodity}
                    <ChevronDown size={12} />
                  </button>
                  <button onClick={() => setShowScope(!showScope)}>
                    <Clock3 size={13} />
                    时间范围
                  </button>
                  {action && (
                    <button
                      className="selected-action"
                      onClick={() => setAction(null)}
                    >
                      {action.name}
                      <X size={11} />
                    </button>
                  )}
                </div>
                <button
                  className="submit-research"
                  title="开始研究"
                  aria-label="开始研究"
                  disabled={busy || !question.trim()}
                  onClick={() => void run()}
                >
                  {busy ? <Spinner /> : <ArrowUp size={19} />}
                </button>
              </div>
              {showScope && (
                <div className="scope-fields">
                  <label>
                    研究品种
                    <input
                      value={commodity}
                      onChange={(e) => {
                        setCommodity(e.target.value);
                        key.current = crypto.randomUUID();
                      }}
                      placeholder="输入中国期货品种"
                    />
                  </label>
                  <label>
                    资料时间范围
                    <input
                      value={period}
                      onChange={(e) => {
                        setPeriod(e.target.value);
                        key.current = crypto.randomUUID();
                      }}
                      placeholder="例如：2026 年 7–10 月"
                    />
                  </label>
                </div>
              )}
            </section>
            <div className="suggestion-label">也可以从一项具体工作开始</div>
            <div className="research-action-grid">
              {actions.map((a, i) => {
                const Icon = [Layers, FileCheck2, Clock3][i % 3];
                return (
                  <button
                    key={a.id}
                    className={
                      "research-action " + (action?.id === a.id ? "chosen" : "")
                    }
                    onClick={() => {
                      choose(a);
                      if (!question)
                        setQuestion(
                          a.name +
                            "：请围绕核心问题整理关键证据、同口径比较和来源。",
                        );
                      key.current = crypto.randomUUID();
                    }}
                  >
                    <span className={"action-icon action-" + (i % 3)}>
                      <Icon size={20} />
                    </span>
                    <h3>
                      {a.name}
                      <ArrowUpRight size={14} />
                    </h3>
                    <p>{a.description}</p>
                  </button>
                );
              })}
            </div>
            <div className="research-status-note">
              {ready?.indexed_documents > 0 ? (
                <>
                  <BookOpen size={13} />
                  {ready.indexed_documents} 份资料已建立索引
                </>
              ) : (
                <>
                  <FileText size={13} />
                  资料库尚未收录研究资料
                </>
              )}
              {!ready?.model_configured && <span>研究模型等待管理员连接</span>}
            </div>
            <footer className="research-principles">
              <span>
                <Check size={12} />
                注明来源
              </span>
              <span>
                <Check size={12} />
                区分计划与实绩
              </span>
              <span>
                <Check size={12} />
                保留历史口径
              </span>
            </footer>
          </main>
        ) : (
          <main className="research-result">
            <button className="back-link" onClick={fresh}>
              <ArrowLeft size={15} />
              开始新研究
            </button>
            {result ? (
              <>
                <header>
                  <div className="eyebrow">RESEARCH RECORD</div>
                  <h1>{result.commodity} · 基本面研究</h1>
                  <div className="research-meta">
                    <Badge state={result.status} />
                    <span>{date(result.created_at)}</span>
                  </div>
                </header>
                <div className="research-progress">
                  <div>
                    <span className="progress-number">1</span>
                    <b>接收研究任务</b>
                    <Check size={15} />
                  </div>
                  <div
                    className={
                      ["queued"].includes(result.status) ? "pending" : ""
                    }
                  >
                    <span className="progress-number">2</span>
                    <b>整理与核对资料</b>
                    {result.status === "running" ? (
                      <Spinner />
                    ) : result.status === "completed" ? (
                      <Check size={15} />
                    ) : null}
                  </div>
                  <div
                    className={result.status === "completed" ? "" : "pending"}
                  >
                    <span className="progress-number">3</span>
                    <b>生成研究记录</b>
                    {result.status === "completed" && <Check size={15} />}
                  </div>
                </div>
                {result.result ? (
                  <article className="research-document">
                    <div className="document-heading">
                      <FileText size={19} />
                      <span>研究记录</span>
                      <button
                        className="text-button"
                        onClick={() => {
                          const blob = new Blob([result.result], {
                            type: "text/plain;charset=utf-8",
                          });
                          const link = document.createElement("a");
                          link.href = URL.createObjectURL(blob);
                          link.download = result.commodity + "-研究记录.txt";
                          link.click();
                          URL.revokeObjectURL(link.href);
                        }}
                      >
                        导出记录 <ArrowUpRight size={13} />
                      </button>
                    </div>
                    <div>{result.result}</div>
                  </article>
                ) : result.status === "failed" ? (
                  <div className="research-failure">
                    <FileText size={27} />
                    <h3>这次研究还未完成</h3>
                    <p>
                      {result.error?.includes("credential")
                        ? "研究模型尚未连接。请由工作区管理员完成连接后继续。"
                        : result.error ||
                          "执行过程中出现问题，研究进度已经保留。"}
                    </p>
                  </div>
                ) : result.status === "waiting_unknown" ? (
                  <div className="research-failure">
                    <h3>有一项执行结果需要核对</h3>
                    <p>
                      当前任务已暂停。管理员核实外部服务回执后，才能继续处理。
                    </p>
                  </div>
                ) : result.status === "cancelled" ? (
                  <Empty
                    title="研究已停止"
                    detail="已有资料和执行记录仍保留在工作区。"
                  />
                ) : (
                  <div className="research-wait">
                    <div className="research-spinner" />
                    <h3>正在整理这次研究</h3>
                    <p>已完成的进度会自动保存，你可以稍后回来查看。</p>
                  </div>
                )}
                {["running", "queued", "waiting_children"].includes(
                  result.status,
                ) && (
                  <button
                    className="back-link"
                    onClick={() =>
                      void api("/tasks/" + result.id + "/cancel", {}).catch(
                        (e) => setNotice(e.message),
                      )
                    }
                  >
                    停止研究
                  </button>
                )}
              </>
            ) : (
              <div className="research-wait">
                <Spinner />
              </div>
            )}
          </main>
        )}
      </div>
      {notice && (
        <div className="toast">
          <span>{notice}</span>
          <button
            className="icon-button"
            aria-label="关闭通知"
            onClick={() => setNotice("")}
          >
            <X size={15} />
          </button>
        </div>
      )}
    </div>
  );
}
createRoot(document.getElementById("app")!).render(<Futures />);
