import { useCallback, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { Answer } from "./markdown";
import { CatalogPager, useBindingCatalog } from "./catalog";
import {
  Activity,
  ArrowLeft,
  ArrowUpRight,
  BookOpen,
  Bot,
  Box,
  Check,
  ChevronRight,
  Code2,
  Database,
  FileText,
  FlaskConical,
  KeyRound,
  Layers,
  Link2,
  Menu,
  Network,
  PanelRightOpen,
  Play,
  Plus,
  RefreshCw,
  Search,
  Settings2,
  ShieldCheck,
  SlidersHorizontal,
  Sparkles,
  Terminal,
  Upload,
  Workflow,
  X,
} from "lucide-react";
import {
  api,
  Badge,
  base64,
  date,
  downloadArtifact,
  Empty,
  Field,
  Login,
  Modal,
  Spinner,
  type Ref,
  type Resource,
  type CatalogPage,
  resourceDetail,
} from "./shared";
import "./console.css";
import "./console-layout.css";
import { ToolGovernance } from "./tool-governance";
import { Notes } from "./notes";

type Page = "agents" | "tools" | "knowledge" | "notes" | "runs" | "services" | "settings";
const nav = [
  { id: "agents", name: "自定义 Agent", icon: Bot },
  { id: "tools", name: "ToolHub", icon: Box },
  { id: "knowledge", name: "知识库", icon: BookOpen },
  { id: "notes", name: "工作记忆", icon: FileText },
  { id: "runs", name: "运行记录", icon: Activity },
  { id: "services", name: "服务与实例", icon: Network },
];
const blankAgent = () => ({
  name: "",
  prompt: "",
  prompts: [],
  skills: [],
  connectors: [],
  knowledge: [],
  child_agents: [],
  tools: ["knowledge_search", "note_save", "artifact_read", "document_read", "run_recall"],
  model: {
    base_url: "https://api.deepseek.com",
    model: "deepseek-flash",
    key_env: "DEEPSEEK_API_KEY",
    thinking: "disabled",
    max_tokens: 4096,
  },
  publication: { enabled: false, app: "futures", name: "", description: "" },
  constraints: [],
  max_steps: 12,
  max_model_attempts: 40,
  model_token_budget: 200000,
  context_bytes: 64000,
  context_tokens: 32000,
  max_children: 2,
});
function Console() {
  const [page, setPage] = useState<Page>("agents"),
    [resources, setResources] = useState<Resource[]>([]),
    [runs, setRuns] = useState<any[]>([]),
    [status, setStatus] = useState<any>({ instances: [] }),
    [ready, setReady] = useState(false),
    [error, setError] = useState(""),
    [notice, setNotice] = useState(""),
    [editor, setEditor] = useState<Resource | null | undefined>(),
    [dialog, setDialog] = useState<{
      kind: string;
      resource?: Resource;
    } | null>(null),
    [search, setSearch] = useState(""),
    [toolKind, setToolKind] = useState("skill"),
    [cursors, setCursors] = useState<string[]>([""]),
    [nextCursor, setNextCursor] = useState(""),
    [mobileNav, setMobileNav] = useState(false),
    [publicationFilter, setPublicationFilter] = useState("all"),
    [catalogLoading, setCatalogLoading] = useState(true);
  const after = cursors[cursors.length - 1];
  const kind =
    page === "tools" ? toolKind : page === "knowledge" ? "knowledge" : "agent";
  const catalogIdentity = JSON.stringify([kind, search, after]);
  const currentCatalog = useRef(catalogIdentity);
  currentCatalog.current = catalogIdentity;
  const requestVersion = useRef(0);
  // Navigation and explicit open intents own the editor session. Saving a new
  // revision must not remount the active editor or discard its trial run.
  const resourceRequest = useRef(0);
  const [editorSession, setEditorSession] = useState(0);
  const [dialogSession, setDialogSession] = useState(0);
  const openEditor = async (resource: Resource | null) => {
    const version = ++resourceRequest.current;
    try {
      const full = resource ? await resourceDetail(resource) : null;
      if (version !== resourceRequest.current) return;
      setEditorSession(version);
      setEditor(full);
    } catch (e) {
      if (version === resourceRequest.current) setNotice((e as Error).message);
    }
  };
  const openDialog = async (kind: string, resource?: Resource) => {
    const version = ++resourceRequest.current;
    try {
      const full = resource ? await resourceDetail(resource) : undefined;
      if (version !== resourceRequest.current) return;
      setDialogSession(version);
      setDialog({ kind, resource: full });
    } catch (e) {
      if (version === resourceRequest.current) setNotice((e as Error).message);
    }
  };
  const load = useCallback(async () => {
    if (currentCatalog.current !== catalogIdentity) return;
    const version = ++requestVersion.current;
    const [r, run, st] = await Promise.allSettled([
      api<CatalogPage>(
        "/catalog?" + new URLSearchParams({ kind, q: search, after }),
      ),
      api<any[]>("/runs"),
      api<any>("/status"),
    ]);
    if (
      version !== requestVersion.current ||
      currentCatalog.current !== catalogIdentity
    )
      return;
    if (
      [r, run, st].some(
        (x) => x.status === "rejected" && x.reason?.status === 401,
      )
    ) {
      setReady(false);
      setError("请使用管理访问令牌登录。");
      return;
    }
    const failures: string[] = [];
    if (r.status === "fulfilled") {
      setResources(r.value.items);
      setNextCursor(r.value.next_cursor);
      for (const [name, ok] of Object.entries(r.value.services))
        if (!ok) failures.push(name);
    } else {
      failures.push("资源目录");
      setNextCursor("");
    }
    if (run.status === "fulfilled") setRuns(run.value);
    else failures.push("运行记录");
    if (st.status === "fulfilled") setStatus(st.value);
    else failures.push("服务状态");
    setReady(true);
    setCatalogLoading(false);
    setError(
      failures.length
        ? failures.join("、") + " 暂不可用；其他服务仍可使用。"
        : "",
    );
  }, [kind, search, after, catalogIdentity]);
  const searchCatalog = (q: string) => {
    requestVersion.current++;
    setCatalogLoading(true);
    setSearch(q);
    setCursors([""]);
    setNextCursor("");
    setResources([]);
  };
  const importInput = useRef<HTMLInputElement>(null);
  useEffect(() => {
    const timer = setTimeout(
      () => void load().catch((e) => setError(e.message)),
      200,
    );
    return () => clearTimeout(timer);
  }, [load]);
  useEffect(() => {
    const id = setInterval(() => void load().catch(() => {}), 7000);
    return () => clearInterval(id);
  }, [load]);
  useEffect(() => {
    if (notice) {
      const id = setTimeout(() => setNotice(""), 6500);
      return () => clearTimeout(id);
    }
  }, [notice]);
  const notify = (message: string) => setNotice(message);
  const act = async (fn: () => Promise<void>) => {
    try {
      await fn();
    } catch (e) {
      notify((e as Error).message);
    }
  };
  if (!ready) {
    return error ? (
      <Login
        error={error}
        retry={() => void load().catch((e) => setError(e.message))}
      />
    ) : (
      <div className="loading-screen">
        <Spinner /> 连接工作区…
      </div>
    );
  }
  const change = (id: Page) => {
    requestVersion.current++;
    resourceRequest.current++;
    setDialog(null);
    setPage(id);
    setMobileNav(false);
    setCatalogLoading(true);
    setEditor(undefined);
    setSearch("");
    setResources([]);
    setCursors([""]);
    setNextCursor("");
  };
  const importFile = async (file: File, kind: string) => {
    if (kind === "skill" && file.name.endsWith(".zip")) {
      const id =
        file.name.replace(/\.[^.]+$/, "").replace(/[^a-zA-Z0-9_-]/g, "-") ||
        "imported-skill";
      await api("/toolhub/assets", {
        kind,
        id,
        spec: { name: id, content: "Bundle SKILL.md" },
        bundle: await base64(file),
      });
      await load();
      notify("Skill 包已登记。请在检测与启停中审阅后启用。");
      return;
    }
    const text = await file.text();
    let resource: any;
    if (file.name.endsWith(".json")) {
      resource = JSON.parse(text);
      if (!resource.kind)
        resource = {
          kind,
          id: file.name.replace(/\.[^.]+$/, ""),
          spec: resource,
        };
    } else {
      resource = {
        kind,
        id:
          file.name.replace(/\.[^.]+$/, "").replace(/[^a-zA-Z0-9_-]/g, "-") ||
          "imported-skill",
        spec: { name: file.name, content: text },
      };
    }
    if (resource.kind !== kind) throw new Error("文件类型与当前资源分类不一致");
    await api("/resources", resource);
    await load();
    notify("资源已导入，并保存为独立版本。");
  };
  const navigation = (
    <>
      {[
        ["构建", nav.slice(0, 3)],
        ["运行与维护", nav.slice(3)],
      ].map(([label, items]) => (
        <div className="nav-group" key={label as string}>
          <div className="nav-caption">{label as string}</div>
          <nav aria-label={label as string}>
            {(items as typeof nav).map((item) => (
              <button
                key={item.id}
                aria-current={page === item.id ? "page" : undefined}
                className={page === item.id ? "active" : ""}
                onClick={() => change(item.id as Page)}
              >
                <item.icon size={18} />
                {item.name}
              </button>
            ))}
          </nav>
        </div>
      ))}
      <div className="nav-group">
        <div className="nav-caption">工作区</div>
        <nav aria-label="工作区">
          <button
            aria-current={page === "settings" ? "page" : undefined}
            className={page === "settings" ? "active" : ""}
            onClick={() => change("settings")}
          >
            <Settings2 size={18} />
            模型与凭证
          </button>
        </nav>
      </div>
    </>
  );
  const agents = resources.filter((r) => r.kind === "agent");
  const visibleAgents = agents.filter(
    (r) =>
      publicationFilter === "all" ||
      (publicationFilter === "published"
        ? r.spec.publication?.enabled
        : !r.spec.publication?.enabled),
  );
  return (
    <div className="platform-shell">
      <a className="skip-link" href="#workspace-content">
        跳转到内容
      </a>
      <aside className="sidebar">
        <a
          className="brand"
          href="#"
          onClick={(e) => {
            e.preventDefault();
            change("agents");
          }}
        >
          <span className="logo-symbol">a</span>
          <span>
            Agent OS<small>管理工作台</small>
          </span>
        </a>
        <div className="workspace-switch">
          <span className="workspace-avatar">
            <Layers size={17} />
          </span>
          <div>
            个人工作区<small>资源 · 配置 · 执行</small>
          </div>
        </div>
        {navigation}
        <div className="sidebar-bottom">
          <div className="nav-caption">业务应用</div>
          <a
            className="business-link"
            href="http://127.0.0.1:8098"
            target="_blank"
            rel="noreferrer"
          >
            <span className="app-icon">
              <Layers size={16} />
            </span>
            研序 · 期货研究
            <ArrowUpRight size={14} />
          </a>
          <div className="profile">
            <span>
              <ShieldCheck size={16} />
            </span>
            <div>
              独立服务 · 统一管理
              <small>Agent OS · v0.6</small>
            </div>
          </div>
        </div>
      </aside>
      <div className="main-shell">
        <div className="topbar">
          <button
            className="icon-button console-menu"
            aria-label="展开导航"
            aria-expanded={mobileNav}
            onClick={() => setMobileNav(true)}
          >
            <Menu size={20} />
          </button>
          <span>
            工作空间 <ChevronRight size={13} />{" "}
            <b>{nav.find((n) => n.id === page)?.name || "模型与凭证"}</b>
            {editor !== undefined && (
              <>
                <ChevronRight size={13} />
                <b>{editor?.spec.name || "新建 Agent"}</b>
              </>
            )}
          </span>
          <div className="topbar-right">
            <span className="deployment">工作区管理</span>
            <button
              className="icon-button"
              aria-label="刷新"
              onClick={() => void act(load)}
            >
              <RefreshCw size={16} />
            </button>
          </div>
        </div>
        {error && (
          <div className="connection-banner" role="alert">
            <span>{error}</span>
            <button className="text-button" onClick={() => void act(load)}>
              重试连接
            </button>
          </div>
        )}
        {editor !== undefined ? (
          <AgentEditor
            key={editorSession}
            resource={editor}
            resources={resources}
            close={() => {
              resourceRequest.current++;
              setEditor(undefined);
            }}
            saved={async (r) => {
              await load();
              if (resourceRequest.current === editorSession) setEditor(r);
            }}
            notify={notify}
          />
        ) : (
          <main className="page-content" id="workspace-content" tabIndex={-1}>
            <header className="page-heading">
              <div>
                <h1>{nav.find((n) => n.id === page)?.name || "模型与凭证"}</h1>
                <p>
                  {
                    {
                      agents:
                        "定义角色与工作方法，连接工具和资料，调试后发布到业务。",
                      tools:
                        "统一管理 Skill、MCP 与提示词，按版本为 Agent 提供能力。",
                      knowledge:
                        "保留原始资料与出处，为 Agent 提供可追溯的检索服务。",
                      runs: "查看执行结果、调用回执和恢复记录。",
                      notes: "管理 Agent 留存的事实与工作记忆，查阅原文、有效状态和修订历史。",
                      services: "查看各服务实例的心跳，以及执行与索引 Worker。",
                      settings: "统一管理模型访问凭证，Agent 通过名称引用。",
                    }[page]
                  }
                </p>
              </div>
              {page === "agents" && (
                <div className="button-row">
                  <input
                    hidden
                    type="file"
                    ref={importInput}
                    accept=".json"
                    onChange={(e) => {
                      const f = e.target.files?.[0];
                      if (f) void act(() => importFile(f, "agent"));
                      e.target.value = "";
                    }}
                  />
                  <button
                    className="button"
                    onClick={() => importInput.current?.click()}
                  >
                    <Upload size={15} />
                    导入
                  </button>
                  <button
                    className="button primary"
                    onClick={() => void openEditor(null)}
                  >
                    <Plus size={16} />
                    创建 Agent
                  </button>
                </div>
              )}
              {page === "knowledge" && (
                <button
                  className="button primary"
                  onClick={() => void openDialog("knowledge")}
                >
                  <Plus size={16} />
                  创建知识库
                </button>
              )}
            </header>
            {page === "agents" && (
              <>
                <div className="section-toolbar">
                  <div className="tabs">
                    {[
                      ["all", "全部"],
                      ["published", "已发布"],
                      ["draft", "未发布"],
                    ].map(([value, label]) => (
                      <button
                        key={value}
                        aria-pressed={publicationFilter === value}
                        className={
                          publicationFilter === value ? "selected" : ""
                        }
                        onClick={() => setPublicationFilter(value)}
                      >
                        {label}
                        <span>
                          {
                            agents.filter(
                              (r) =>
                                value === "all" ||
                                (value === "published"
                                  ? r.spec.publication?.enabled
                                  : !r.spec.publication?.enabled),
                            ).length
                          }
                        </span>
                      </button>
                    ))}
                  </div>
                  <label className="search-input">
                    <Search size={16} />
                    <input
                      aria-label="搜索 Agent"
                      placeholder="搜索 Agent…"
                      value={search}
                      onChange={(e) => searchCatalog(e.target.value)}
                    />
                  </label>
                </div>
                <div className="catalog-context">
                  <span>
                    当前页 ·{" "}
                    {catalogLoading
                      ? "正在读取目录…"
                      : `${visibleAgents.length} 个 Agent`}
                  </span>
                  <span>选择 Agent 进入配置与试运行</span>
                </div>
                {catalogLoading && (
                  <div className="catalog-loading" role="status">
                    <Spinner /> 正在加载资源
                  </div>
                )}
                {!catalogLoading && !visibleAgents.length && (
                  <Empty
                    title={search ? "没有匹配的 Agent" : "这个分类还没有 Agent"}
                    detail={
                      search
                        ? "试试其他名称或 ID，或清除搜索条件。"
                        : "创建 Agent 后，可在发布设置中连接业务入口。"
                    }
                  />
                )}
                <div className="agent-grid" aria-busy={catalogLoading}>
                  {visibleAgents.map((r, i) => (
                    <button
                      className="agent-card"
                      key={r.id}
                      onClick={() => void openEditor(r)}
                    >
                      <div className="card-top">
                        <span className={"agent-icon color-" + (i % 3)}>
                          <Bot size={23} />
                        </span>
                        <span className="version">v{r.revision}</span>
                      </div>
                      <h3>{r.spec.name}</h3>
                      <p>
                        {r.spec.publication?.description ||
                          r.spec.prompt ||
                          "尚未填写角色与工作方法"}
                      </p>
                      <div className="capability-chips">
                        <span>
                          <Box size={12} />
                          {r.spec.skill_count || 0} Skill
                        </span>
                        <span>
                          <Link2 size={12} />
                          {r.spec.connector_count || 0} MCP
                        </span>
                        <span>
                          <BookOpen size={12} />
                          {r.spec.knowledge_count || 0} 知识库
                        </span>
                      </div>
                      <footer>
                        <span>
                          <i className="subtle-dot" />
                          {r.spec.publication?.enabled ? (
                            <span className="publication-label">已发布</span>
                          ) : (
                            "未发布"
                          )}
                          <span>{r.spec.model?.model || "未设置模型"}</span>
                        </span>
                        <ArrowUpRight size={16} />
                      </footer>
                    </button>
                  ))}
                  <button
                    className="create-card"
                    onClick={() => void openEditor(null)}
                  >
                    <span>
                      <Plus size={23} />
                    </span>
                    <h3>创建你的下一个 Agent</h3>
                    <p>定义角色，连接它需要的能力</p>
                  </button>
                </div>
                <div className="onboarding-strip">
                  <span className="strip-icon">
                    <Workflow size={22} />
                  </span>
                  <div>
                    <h3>从能力到业务，一条清晰的路径</h3>
                    <p>上传资源 → 配置 Agent → 右侧试运行 → 发布为业务入口</p>
                  </div>
                  <button
                    className="text-button"
                    onClick={() => void openEditor(null)}
                  >
                    配置与发布 Agent <ArrowUpRight size={15} />
                  </button>
                </div>
              </>
            )}
            {page === "tools" && (
              <ToolLibrary
                resources={resources}
                loading={catalogLoading}
                kind={toolKind}
                setKind={(k) => {
                  setToolKind(k);
                  searchCatalog("");
                }}
                query={search}
                setQuery={searchCatalog}
                edit={(kind, resource) => void openDialog(kind, resource)}
                importFile={(f, k) => void act(() => importFile(f, k))}
              />
            )}
            {page === "knowledge" && (
              <Knowledge
                resources={resources}
                loading={catalogLoading}
                queryText={search}
                searchCatalog={searchCatalog}
                notify={notify}
                edit={(r) => void openDialog("knowledge", r)}
              />
            )}
            {page === "runs" && <Runs runs={runs} notify={notify} />}
            {page === "notes" && <Notes notify={notify} />}
            {page === "services" && <Services status={status} />}
            {page === "settings" && (
              <Settings notify={notify} saved={load} status={status} />
            )}
            {["agents", "tools", "knowledge"].includes(page) && (
              <CatalogPager
                after={after}
                next={nextCursor}
                previous={cursors.length > 1}
                advance={() => {
                  requestVersion.current++;
                  setCatalogLoading(true);
                  setCursors([...cursors, nextCursor]);
                  setResources([]);
                  setNextCursor("");
                }}
                back={() => {
                  requestVersion.current++;
                  setCatalogLoading(true);
                  setCursors(cursors.slice(0, -1));
                  setResources([]);
                  setNextCursor("");
                }}
              />
            )}
          </main>
        )}
      </div>
      {mobileNav && (
        <Modal title="工作区导航" close={() => setMobileNav(false)}>
          <div className="modal-body drawer-navigation">
            {navigation}
            <a
              className="business-link"
              href="http://127.0.0.1:8098"
              target="_blank"
              rel="noreferrer"
            >
              <Layers size={17} />
              研序 · 期货研究
              <ArrowUpRight size={14} />
            </a>
          </div>
        </Modal>
      )}
      {dialog && (
        <ResourceDialog
          key={dialogSession}
          {...dialog}
          resources={resources}
          close={() => {
            resourceRequest.current++;
            setDialog(null);
          }}
          save={async (kind, id, spec) => {
            await api(kind === "skill" ? "/toolhub/assets" : "/resources", {
              kind,
              id,
              spec,
              ...(kind === "skill" && dialog.resource
                ? { base_revision: dialog.resource.revision }
                : {}),
            });
            await load();
            if (resourceRequest.current !== dialogSession) return;
            resourceRequest.current++;
            setDialog(null);
            notify("已保存新版本。");
          }}
        />
      )}
      {notice && (
        <div className="toast" role="status">
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
function Bindings({
  kind,
  chosen,
  change,
  excludeID,
}: {
  kind: string;
  chosen: Ref[];
  resources: Resource[];
  change: (v: Ref[]) => void;
  excludeID?: string;
}) {
  const catalog = useBindingCatalog(kind);
  const visible = catalog.items.filter((r) => r.id !== excludeID);
  const options = [
    ...chosen
      .filter((c) => !visible.some((r) => r.id === c.id))
      .map((c) => ({
        kind,
        id: c.id,
        revision: c.revision,
        spec: { name: c.id },
      })),
    ...visible,
  ];
  return (
    <div className="binding-list">
      <input
        aria-label="搜索可绑定资源"
        placeholder="搜索名称或 ID…"
        value={catalog.query}
        onChange={(e) => catalog.search(e.target.value)}
      />
      {catalog.error && (
        <small className="inline-warning">{catalog.error}</small>
      )}
      {chosen.some((c) => !visible.some((r) => r.id === c.id)) && (
        <small>
          已绑定的历史版本或其他页资源仍保留；勾选表示绑定，不代表验活通过。
        </small>
      )}
      {options.length ? (
        options.map((r) => {
          const current = chosen.find((x) => x.id === r.id);
          return (
            <label
              key={r.id}
              className={"binding-option " + (current ? "checked" : "")}
            >
              <input
                type="checkbox"
                checked={!!current}
                onChange={(e) =>
                  change(
                    e.target.checked
                      ? [...chosen, { id: r.id, revision: r.revision }]
                      : chosen.filter((x) => x.id !== r.id),
                  )
                }
              />
              <span className="resource-small-icon">
                {kind === "knowledge" ? (
                  <BookOpen size={17} />
                ) : kind === "agent" ? (
                  <Bot size={17} />
                ) : (
                  <Box size={17} />
                )}
              </span>
              <span>
                <b>{r.spec.name || r.id}</b>
                <small>
                  {r.id} · v{current?.revision || r.revision}
                  {current && current.revision !== r.revision
                    ? "（保留历史绑定）"
                    : ""}
                </small>
              </span>
              {current && current.revision !== r.revision && (
                <button
                  type="button"
                  className="text-button"
                  onClick={(e) => {
                    e.preventDefault();
                    change(
                      chosen.map((x) =>
                        x.id === r.id ? { id: r.id, revision: r.revision } : x,
                      ),
                    );
                  }}
                >
                  升级到 v{r.revision}
                </button>
              )}
            </label>
          );
        })
      ) : (
        <div className="inline-empty">
          暂无
          {
            (
              {
                skill: " Skill",
                prompt: "提示词",
                connector: " MCP 连接",
                knowledge: "知识库",
                agent: " Agent",
              } as any
            )[kind]
          }
          。可以修改搜索条件，或在对应资源页创建。
        </div>
      )}
      <div className="button-row">
        {catalog.after && (
          <button type="button" className="text-button" onClick={catalog.reset}>
            返回第一页
          </button>
        )}
        {catalog.next && (
          <button
            type="button"
            className="text-button"
            onClick={catalog.advance}
          >
            下一页资源
          </button>
        )}
      </div>
    </div>
  );
}
function AgentEditor({
  resource,
  resources,
  close,
  saved,
  notify,
}: {
  resource: Resource | null;
  resources: Resource[];
  close: () => void;
  saved: (r: Resource) => Promise<void>;
  notify: (m: string) => void;
}) {
  const [draft, setDraft] = useState<any>({
      ...blankAgent(),
      ...resource?.spec,
    }),
    [id, setID] = useState(resource?.id || ""),
    [tab, setTab] = useState("prompt"),
    [busy, setBusy] = useState(false),
    [test, setTest] = useState(""),
    [run, setRun] = useState<any>(null),
    [runID, setRunID] = useState(""),
    [events, setEvents] = useState<any[]>([]);
  const update = (key: string, value: any) =>
    setDraft((d: any) => ({ ...d, [key]: value }));
  useEffect(() => {
    if (!runID) return;
    let alive = true;
    const poll = async () => {
      try {
        const [r, e] = await Promise.all([
          api("/runs/" + runID),
          api<any[]>("/runs/" + runID + "/events"),
        ]);
        if (alive) {
          setRun(r);
          setEvents(e);
        }
      } catch (e) {
        if (alive) notify((e as Error).message);
      }
    };
    void poll();
    const interval = setInterval(() => void poll(), 1800);
    return () => {
      alive = false;
      clearInterval(interval);
    };
  }, [runID]);
  const persist = async (testing = false) => {
    setBusy(true);
    try {
      if (testing && !test.trim()) throw new Error("先输入试运行任务");
      const r = await api<Resource>("/resources", {
        kind: "agent",
        id,
        spec: draft,
      });
      await saved(r);
      if (testing) {
        const accepted = await api("/runs", {
          agent: { id: r.id, revision: r.revision },
          task: test,
          constraints: [],
        });
        setRunID(accepted.id);
        notify("已保存版本并开始真实试运行。");
      } else
        notify(
          draft.publication?.enabled
            ? `已发布 v${r.revision}，业务工作台现在使用这个版本。`
            : "Agent 已保存为新版本。",
        );
    } catch (e) {
      notify((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  return (
    <div
      className="agent-editor"
      id="workspace-content"
      tabIndex={-1}
      role="main"
    >
      <div className="editor-heading">
        <button
          className="icon-button"
          aria-label="返回 Agent 列表"
          onClick={close}
        >
          <ArrowLeft size={18} />
        </button>
        <span className="agent-icon small color-0">
          <Bot size={19} />
        </span>
        <div>
          <h2>{draft.name || "新建 Agent"}</h2>
          <small>
            {resource
              ? `${resource.id} · 当前 v${resource.revision}`
              : "为一类工作定义可复用的执行方式"}
          </small>
        </div>
        <button
          className="button primary"
          disabled={busy}
          onClick={() => void persist()}
        >
          {busy ? <Spinner /> : <Check size={15} />}
          {draft.publication?.enabled ? "保存并发布" : "保存版本"}
        </button>
      </div>
      <div className="editor-layout">
        <section className="configuration">
          <div className="tabs editor-tabs">
            {[
              ["prompt", "角色与提示词"],
              ["tools", "能力绑定"],
              ["knowledge", "知识库"],
              ["model", "模型与执行"],
              ["publish", "发布"],
            ].map(([key, name]) => (
              <button
                key={key}
                className={tab === key ? "selected" : ""}
                onClick={() => setTab(key)}
              >
                {name}
              </button>
            ))}
          </div>
          <div className="configuration-body">
            {tab === "prompt" && (
              <>
                <div className="two-fields">
                  <Field label="Agent 名称">
                    <input
                      placeholder="例如：期货基本面研究员"
                      value={draft.name}
                      onChange={(e) => update("name", e.target.value)}
                    />
                  </Field>
                  <Field label="唯一标识">
                    <input
                      placeholder="futures-research"
                      value={id}
                      disabled={!!resource}
                      onChange={(e) => setID(e.target.value)}
                    />
                  </Field>
                </div>
                <Field
                  label="角色与工作原则"
                  hint="说明任务目标、工作方法、证据要求和输出形式。已有任务会保留它使用的版本。"
                >
                  <textarea
                    className="prompt-editor"
                    placeholder={
                      "你是一位……\n你的任务是……\n工作步骤……\n输出要求……"
                    }
                    value={draft.prompt}
                    onChange={(e) => update("prompt", e.target.value)}
                  />
                </Field>
                <Field
                  label="固定约束（每行一条）"
                  hint="每次请求保留，独立于上下文摘要。"
                >
                  <textarea
                    value={(draft.constraints || []).join("\n")}
                    onChange={(e) =>
                      update(
                        "constraints",
                        e.target.value.split("\n").filter(Boolean),
                      )
                    }
                  />
                </Field>
                <h3 className="section-label">复用提示词</h3>
                <Bindings
                  kind="prompt"
                  chosen={draft.prompts || []}
                  resources={resources}
                  change={(v) => update("prompts", v)}
                />
              </>
            )}
            {tab === "tools" && (
              <>
                <h3 className="section-label">
                  Skill <span>可复用的工作方法</span>
                </h3>
                <Bindings
                  kind="skill"
                  chosen={draft.skills || []}
                  resources={resources}
                  change={(v) => update("skills", v)}
                />
                <h3 className="section-label">
                  MCP <span>连接外部数据和操作能力</span>
                </h3>
                <Bindings
                  kind="connector"
                  chosen={draft.connectors || []}
                  resources={resources}
                  change={(v) => update("connectors", v)}
                />
                <h3 className="section-label">基础工具</h3>
                <div className="builtin-grid">
                  {[
                    ["knowledge_search", "检索工作资料"],
                    ["note_save", "保存有出处的记录"],
                    ["note_revise", "修订本 Agent 的记录"],
                    ["note_retire", "撤回本 Agent 的记录"],
                    ["artifact_read", "回读原始执行记录"],
                    ["run_recall", "找回本任务的历史证据"],
                    ["document_read", "阅读完整资料"],
                    ["spawn_agent", "委派子 Agent"],
                    ["sandbox_exec", "容器内运行代码"],
                  ].map(([key, label]) => (
                    <label key={key}>
                      <input
                        type="checkbox"
                        checked={draft.tools.includes(key)}
                        onChange={(e) =>
                          update(
                            "tools",
                            e.target.checked
                              ? [...draft.tools, key]
                              : draft.tools.filter((v: string) => v !== key),
                          )
                        }
                      />
                      {label}
                    </label>
                  ))}
                </div>
                <h3 className="section-label">允许委派的 Agent</h3>
                <Bindings
                  kind="agent"
                  excludeID={id}
                  chosen={draft.child_agents || []}
                  resources={resources.filter((r) => r.id !== id)}
                  change={(v) => update("child_agents", v)}
                />
              </>
            )}
            {tab === "knowledge" && (
              <>
                <div className="info-banner">
                  <BookOpen size={20} />
                  <div>
                    <b>给 Agent 一份有出处的知识</b>
                    <p>
                      绑定后自动获得检索能力。索引方式与模型由知识库服务管理。
                    </p>
                  </div>
                </div>
                <Bindings
                  kind="knowledge"
                  chosen={draft.knowledge || []}
                  resources={resources}
                  change={(v) => update("knowledge", v)}
                />
              </>
            )}
            {tab === "publish" && (
              <>
                <div className="info-banner">
                  <ArrowUpRight size={20} />
                  <div>
                    <b>把这个 Agent 放到业务工作台</b>
                    <p>
                      名称和说明会显示在业务工作台，用户点击后向这个 Agent
                      提交任务。
                    </p>
                  </div>
                </div>
                <label className="binding-option">
                  <input
                    type="checkbox"
                    checked={!!draft.publication?.enabled}
                    onChange={(e) =>
                      update("publication", {
                        ...draft.publication,
                        app: "futures",
                        enabled: e.target.checked,
                        name: draft.publication?.name || draft.name,
                      })
                    }
                  />
                  <span>
                    <b>发布到期货研究工作台</b>
                    <small>
                      保存版本后生效；关闭并保存即可撤下入口，已有任务继续保留。
                    </small>
                  </span>
                </label>
                <Field label="业务端显示名称">
                  <input
                    value={draft.publication?.name || ""}
                    placeholder={draft.name}
                    onChange={(e) =>
                      update("publication", {
                        ...draft.publication,
                        app: "futures",
                        name: e.target.value,
                      })
                    }
                  />
                </Field>
                <Field label="这位 Agent 能帮用户做什么">
                  <textarea
                    value={draft.publication?.description || ""}
                    placeholder="例如：围绕供给变化和库存结构，收集并核对基本面证据。"
                    onChange={(e) =>
                      update("publication", {
                        ...draft.publication,
                        app: "futures",
                        description: e.target.value,
                      })
                    }
                  />
                </Field>
                <h3 className="section-label">期货工作台收集的任务参数</h3>
                <div className="binding-list">
                  {[
                    ["品种", "必填，例如豆粕、甲醇"],
                    ["资料时间范围", "近月、远月或指定日历区间"],
                    ["研究问题", "用户这次要核对的具体问题"],
                  ].map(([label, hint]) => (
                    <div className="binding-option" key={label}>
                      <FileText size={18} />
                      <span>
                        <b>{label}</b>
                        <small>{hint}</small>
                      </span>
                    </div>
                  ))}
                </div>
                <p className="field-hint">
                  提示词、Skill、MCP、知识库与固定约束沿用本 Agent
                  配置。业务端只显示名称、说明和任务结果。
                </p>
              </>
            )}
            {tab === "model" && (
              <>
                <div className="info-banner">
                  <Bot size={20} />
                  <div>
                    <b>DeepSeek Harness</b>
                    <p>
                      DSH 执行 Agent
                      循环与上下文压缩。中台管理任务、凭证和调用回执。
                    </p>
                  </div>
                </div>
                <h3 className="section-label">模型连接</h3>
                <Field label="服务地址">
                  <input
                    value={draft.model.base_url}
                    onChange={(e) =>
                      update("model", {
                        ...draft.model,
                        base_url: e.target.value,
                      })
                    }
                  />
                </Field>
                <div className="two-fields">
                  <Field label="模型名称">
                    <input
                      value={draft.model.model}
                      onChange={(e) =>
                        update("model", {
                          ...draft.model,
                          model: e.target.value,
                        })
                      }
                    />
                  </Field>
                  <Field label="凭证名称">
                    <input
                      value={draft.model.key_env}
                      onChange={(e) =>
                        update("model", {
                          ...draft.model,
                          key_env: e.target.value,
                        })
                      }
                    />
                  </Field>
                </div>
                <h3 className="section-label">执行预算</h3>
                <div className="two-fields">
                  <Field label="思考模式（兼容 DeepSeek）">
                    <select
                      value={draft.model.thinking || ""}
                      onChange={(e) =>
                        update("model", {
                          ...draft.model,
                          thinking: e.target.value,
                          reasoning_effort: "",
                        })
                      }
                    >
                      <option value="">使用供应商默认值</option>
                      <option value="disabled">关闭 · 日常收集与整理</option>
                      <option value="enabled">开启 · 复杂核验</option>
                    </select>
                  </Field>
                  <Field label="单次输出上限 / tokens">
                    <input
                      type="number"
                      min={1}
                      max={32768}
                      value={draft.model.max_tokens || 4096}
                      onChange={(e) =>
                        update("model", {
                          ...draft.model,
                          max_tokens: Number(e.target.value),
                        })
                      }
                    />
                  </Field>
                </div>
                <div className="two-fields">
                  {[
                    ["max_steps", "最多模型步骤"],
                    [
                      "max_model_attempts",
                      "整项任务模型尝试上限（含子任务及重试）",
                    ],
                    ["model_token_budget", "整项任务 token 预算（含子任务）"],
                    ["context_tokens", "上下文预算 / 估算 tokens"],
                    ["max_children", "最多直属子任务"],
                  ].map(([key, name]) => (
                    <Field key={key} label={name}>
                      <input
                        type="number"
                        value={draft[key]}
                        onChange={(e) => update(key, Number(e.target.value))}
                      />
                    </Field>
                  ))}
                </div>
                <p className="field-hint">
                  修改预算会随 Agent
                  生成新版本。所有模型调用都会保留实际请求与结果。
                </p>
              </>
            )}
          </div>
        </section>
        <aside className="playground">
          <header>
            <span>
              <FlaskConical size={17} />
              试运行
            </span>
            <span className="version">Playground</span>
          </header>
          <div className="playground-body">
            {!run ? (
              <div className="playground-empty">
                <span>
                  <Bot size={30} />
                </span>
                <h3>试试它能否完成任务</h3>
                <p>输入一个真实问题，检查工具调用、检索结果和最终回答。</p>
                <div className="hint-chips">
                  <span>提示词效果</span>
                  <span>能力连通性</span>
                  <span>执行轨迹</span>
                </div>
              </div>
            ) : (
              <>
                <div className="chat-user">{run.task}</div>
                <div className="run-status">
                  <Badge state={run.status} />
                  <small>步骤 {run.step}</small>
                </div>
                {run.state?.result && (
                  <article className="answer-text">
                    <Answer>{run.state.result}</Answer>
                  </article>
                )}
                {run.state?.error && (
                  <div className="error-message">{run.state.error}</div>
                )}
                <details className="execution-details">
                  <summary>
                    执行轨迹 <span>{events.length} 条</span>
                  </summary>
                  {events.map((e) => (
                    <div className="trace-row" key={e.seq}>
                      <i />
                      <div>
                        <b>
                          {(
                            {
                              accepted: "任务已登记",
                              claimed: "开始执行",
                              model_started: "请求模型",
                              model_completed: "模型返回",
                              tool_started: "调用能力",
                              tool_completed: "能力执行完成",
                              checkpoint: "保存进度",
                              model_failed: "模型调用失败",
                            } as any
                          )[e.kind] || e.kind}
                        </b>
                        <small>{date(e.created_at)}</small>
                        <code>{JSON.stringify(e.payload)}</code>
                      </div>
                    </div>
                  ))}
                </details>
                {["running", "queued", "waiting_children"].includes(
                  run.status,
                ) && (
                  <button
                    className="text-button"
                    onClick={() =>
                      void api("/runs/" + run.id + "/cancel", {}).catch((e) =>
                        notify(e.message),
                      )
                    }
                  >
                    停止这次试运行
                  </button>
                )}
              </>
            )}
          </div>
          <div className="playground-compose">
            <textarea
              aria-label="试运行任务"
              placeholder="给这个 Agent 一个任务…"
              value={test}
              onChange={(e) => setTest(e.target.value)}
            />
            <div>
              <small>保存新版本后执行，使用已绑定的真实服务。</small>
              <button
                className="button primary"
                disabled={busy || !test.trim()}
                onClick={() => void persist(true)}
              >
                {busy ? <Spinner /> : <Play size={14} />}试运行
              </button>
            </div>
          </div>
        </aside>
      </div>
    </div>
  );
}
function ToolLibrary({
  resources,
  loading,
  edit,
  importFile,
  kind,
  setKind,
  query,
  setQuery,
}: {
  resources: Resource[];
  loading: boolean;
  edit: (kind: string, r?: Resource) => void;
  importFile: (f: File, k: string) => void;
  kind: string;
  setKind: (kind: string) => void;
  query: string;
  setQuery: (query: string) => void;
}) {
  const file = useRef<HTMLInputElement>(null);
  return (
    <>
      <div className="section-toolbar">
        <div className="tabs">
          {[
            ["skill", "Skill"],
            ["connector", "MCP 连接"],
            ["prompt", "提示词"],
          ].map(([k, label]) => (
            <button
              key={k}
              className={kind === k ? "selected" : ""}
              onClick={() => setKind(k)}
            >
              {label}
              {kind === k && <span>{resources.length}</span>}
            </button>
          ))}
        </div>
        <div className="button-row">
          <input
            hidden
            ref={file}
            type="file"
            accept={
              kind === "connector"
                ? ".json"
                : kind === "skill"
                  ? ".md,.txt,.json,.zip"
                  : ".md,.txt,.json"
            }
            onChange={(e) => {
              const f = e.target.files?.[0];
              if (f) importFile(f, kind);
              e.target.value = "";
            }}
          />
          <button className="button" onClick={() => file.current?.click()}>
            <Upload size={15} />
            上传{kind === "connector" ? "配置" : "文件"}
          </button>
          <button className="button primary" onClick={() => edit(kind)}>
            <Plus size={16} />
            {kind === "connector" ? "连接 MCP" : "创建资源"}
          </button>
        </div>
      </div>
      <div className="resource-intro">
        <span className="agent-icon color-2">
          {kind === "connector" ? <Link2 size={24} /> : <Box size={24} />}
        </span>
        <div>
          <h3>
            {kind === "skill"
              ? "工作方法，也是一种能力"
              : kind === "connector"
                ? "连接外部服务"
                : "把稳定的指令单独管理"}
          </h3>
          <p>
            {kind === "skill"
              ? "上传 Markdown 工作方法，或编写自己的 Skill。每个资源独立保存，多个 Agent 可以复用。"
              : kind === "connector"
                ? "通过 Streamable HTTP 发现并选择工具。连接配置和权限由中台管理。"
                : "角色规范、输出格式和检查规则都可以成为版本化提示词。"}
          </p>
        </div>
      </div>
      <label className="search-input compact">
        <Search size={16} />
        <input
          aria-label="搜索工具资源"
          placeholder="搜索资源…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
      </label>
      <div className="resource-table">
        <div className="resource-table-head">
          <span>资源</span>
          <span>说明</span>
          <span>版本</span>
          <span />
        </div>
        {resources
          .filter((r) => r.kind === kind)
          .map((r) => (
            <div
              className="resource-row"
              key={`${r.kind}/${r.id}@${r.revision}`}
            >
              <span>
                <span className="resource-small-icon">
                  {kind === "connector" ? (
                    <Link2 size={18} />
                  ) : (
                    <FileText size={18} />
                  )}
                </span>
                <span>
                  <button className="text-button" onClick={() => edit(kind, r)}>
                    <b>{r.spec.name || r.id}</b>
                  </button>
                  <small>{r.id}</small>
                </span>
              </span>
              <p>{r.spec.content?.slice(0, 100) || r.spec.endpoint}</p>
              <span className="version">v{r.revision}</span>
              {kind === "prompt" ? (
                <button
                  className="icon-button"
                  aria-label="编辑资源"
                  onClick={() => edit(kind, r)}
                >
                  <ChevronRight size={16} />
                </button>
              ) : (
                <ToolGovernance resource={r} />
              )}
            </div>
          ))}
        {!resources.some((r) => r.kind === kind) &&
          (loading ? (
            <div className="catalog-loading" role="status">
              <Spinner /> 正在读取资源目录…
            </div>
          ) : (
            <Empty
              title={query ? "没有匹配的资源" : "还没有资源"}
              detail={
                query
                  ? "调整搜索词后再试。"
                  : "添加独立资源后，即可在 Agent 中选择和绑定。"
              }
            />
          ))}
      </div>
    </>
  );
}
function ResourceDialog({
  kind,
  resource,
  resources,
  close,
  save,
}: {
  kind: string;
  resource?: Resource;
  resources: Resource[];
  close: () => void;
  save: (kind: string, id: string, spec: any) => Promise<void>;
}) {
  const [id, setID] = useState(resource?.id || ""),
    [spec, setSpec] = useState<any>(
      resource?.spec || {
        name: "",
        content: "",
        description: "",
        engine: "local",
        chunk_size: 900,
        dimensions: 1024,
        embedding: {
          base_url: "http://127.0.0.1:8080/v1",
          model: "Qwen/Qwen3-Embedding-0.6B",
          key_env: "",
        },
        query_prefix:
          "Instruct: Retrieve evidence relevant to this research question.\nQuery: ",
        endpoint: "",
        key_env: "",
        protocol: "2025-11-25",
        tools: [],
        read_only: false,
        agent: { id: "", revision: 1 },
        instruction: "",
        constraints: [],
      },
    ),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  const set = (key: string, value: any) =>
    setSpec((s: any) => ({ ...s, [key]: value }));
  const perform = async (fn: () => Promise<void>) => {
    setBusy(true);
    setError("");
    try {
      await fn();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  const submit = async () => {
    let clean: any;
    if (kind === "knowledge") {
      const {
        name,
        description,
        engine,
        endpoint,
        key_env,
        embedding,
        dimensions,
        query_prefix,
        chunk_size,
      } = spec;
      clean = {
        name,
        description,
        engine,
        endpoint,
        key_env,
        embedding,
        dimensions,
        query_prefix,
        chunk_size,
      };
    } else if (kind === "connector") {
      const { name, endpoint, key_env, protocol, tools, read_only } = spec;
      clean = { name, endpoint, key_env, protocol, tools, read_only };
    } else {
      clean = { name: spec.name, content: spec.content };
    }
    await save(kind, id, clean);
  };
  return (
    <Modal
      title={
        (resource ? "编辑" : "创建") +
        (
          {
            knowledge: "知识库",
            connector: " MCP 连接",
            skill: " Skill",
            prompt: "提示词",
          } as any
        )[kind]
      }
      close={close}
      wide
    >
      <div className="modal-body">
        <div className="two-fields">
          <Field label="名称">
            <input
              value={spec.name}
              onChange={(e) => set("name", e.target.value)}
            />
          </Field>
          <Field label="唯一标识">
            <input
              placeholder="lowercase-id"
              value={id}
              disabled={!!resource}
              onChange={(e) => setID(e.target.value)}
            />
          </Field>
        </div>
        {["skill", "prompt"].includes(kind) && (
          <Field label="内容">
            <textarea
              className="code-editor"
              value={spec.content}
              onChange={(e) => set("content", e.target.value)}
              placeholder="描述工作方法、步骤、约束与预期输出…"
            />
          </Field>
        )}
        {kind === "skill" && resource && (
          <p className="field-hint">
            保存时保留 v{resource.revision} 的全部引用文件，并更新
            SKILL.md。新版本需要重新检测和审阅；更换附件请上传完整 ZIP 包。
          </p>
        )}
        {kind === "connector" && (
          <>
            <Field label="MCP 服务地址">
              <input
                placeholder="https://service.example/mcp"
                value={spec.endpoint}
                onChange={(e) => set("endpoint", e.target.value)}
              />
            </Field>
            <Field label="凭证引用（可留空）">
              <input
                value={spec.key_env}
                onChange={(e) => set("key_env", e.target.value)}
              />
            </Field>
            <label className="checkbox-line">
              <input
                type="checkbox"
                checked={spec.read_only}
                onChange={(e) => set("read_only", e.target.checked)}
              />
              所选工具全部只读，允许失败后安全重试
            </label>
            <button
              className="button"
              disabled={busy}
              onClick={() =>
                void perform(async () => {
                  const tools = await api("/connectors/discover", {
                    name: id,
                    endpoint: spec.endpoint,
                    key_env: spec.key_env,
                    protocol: "2025-11-25",
                    tools: [],
                    read_only: spec.read_only,
                  });
                  set("tools", tools);
                })
              }
            >
              <RefreshCw size={15} />
              发现工具
            </button>
            <div className="discovered-tools">
              {spec.tools.map((t: any) => (
                <div key={t.name}>
                  <Code2 size={16} />
                  <span>
                    <b>{t.name}</b>
                    <small>{t.description}</small>
                  </span>
                  <button
                    className="icon-button"
                    aria-label={"移除 " + t.name}
                    onClick={() =>
                      set(
                        "tools",
                        spec.tools.filter((x: any) => x.name !== t.name),
                      )
                    }
                  >
                    <X size={14} />
                  </button>
                </div>
              ))}
            </div>
            <p className="field-hint">
              协议版本 2025-11-25。移除不希望开放的工具后保存。
            </p>
          </>
        )}
        {kind === "knowledge" && (
          <>
            <Field label="说明">
              <input
                value={spec.description}
                onChange={(e) => set("description", e.target.value)}
              />
            </Field>
            <Field label="检索引擎">
              <select
                value={spec.engine}
                onChange={(e) => set("engine", e.target.value)}
              >
                <option value="local">本地文本检索 · 无需模型</option>
                <option value="milvus">向量 RAG · Milvus + Embedding</option>
                <option value="lightrag">图谱 RAG · LightRAG</option>
              </select>
            </Field>
            {spec.engine !== "local" && (
              <>
                <Field
                  label={
                    spec.engine === "milvus"
                      ? "Milvus REST 地址"
                      : "LightRAG 专属知识库地址"
                  }
                >
                  <input
                    value={spec.endpoint}
                    placeholder={
                      spec.engine === "milvus"
                        ? "http://127.0.0.1:19530"
                        : "http://127.0.0.1:9621"
                    }
                    onChange={(e) => set("endpoint", e.target.value)}
                  />
                </Field>
                <Field label="服务凭证名称（可留空）">
                  <input
                    value={spec.key_env}
                    onChange={(e) => set("key_env", e.target.value)}
                  />
                </Field>
              </>
            )}
            {spec.engine === "milvus" && (
              <>
                <div className="divider-label">Embedding 连接</div>
                <Field label="模型预设">
                  <select
                    value={spec.embedding.model}
                    onChange={(e) => {
                      set("embedding", {
                        ...spec.embedding,
                        model: e.target.value,
                      });
                      set(
                        "dimensions",
                        e.target.value.includes("4B") ? 2560 : 1024,
                      );
                      set(
                        "query_prefix",
                        e.target.value.includes("Qwen")
                          ? "Instruct: Retrieve evidence relevant to this research question.\nQuery: "
                          : "",
                      );
                    }}
                  >
                    <option>Qwen/Qwen3-Embedding-0.6B</option>
                    <option>Qwen/Qwen3-Embedding-4B</option>
                    <option>BAAI/bge-m3</option>
                  </select>
                </Field>
                <Field label="OpenAI 兼容 Embedding 地址">
                  <input
                    value={spec.embedding.base_url}
                    onChange={(e) =>
                      set("embedding", {
                        ...spec.embedding,
                        base_url: e.target.value,
                      })
                    }
                  />
                </Field>
                <div className="two-fields">
                  <Field label="向量维度">
                    <input
                      type="number"
                      value={spec.dimensions}
                      onChange={(e) =>
                        set("dimensions", Number(e.target.value))
                      }
                    />
                  </Field>
                  <Field label="Embedding 凭证名称">
                    <input
                      value={spec.embedding.key_env}
                      onChange={(e) =>
                        set("embedding", {
                          ...spec.embedding,
                          key_env: e.target.value,
                        })
                      }
                    />
                  </Field>
                </div>
                <Field label="查询前缀">
                  <textarea
                    value={spec.query_prefix}
                    onChange={(e) => set("query_prefix", e.target.value)}
                  />
                </Field>
              </>
            )}
            {spec.engine === "lightrag" && (
              <div className="info-banner">
                <Network size={20} />
                <p>
                  LightRAG 的抽取模型和 Embedding
                  在独立服务端配置。每个知识库版本使用独立的服务空间，返回关系线索与来源片段。
                </p>
              </div>
            )}
            <Field label="本地分段长度 / 字符">
              <input
                type="number"
                value={spec.chunk_size}
                onChange={(e) => set("chunk_size", Number(e.target.value))}
              />
            </Field>
            <p className="field-hint">
              新配置生成新版本。原文件保留，旧 Agent
              仍使用原绑定；新版本需重新上传并建索引。
            </p>
          </>
        )}
        {error && <div className="error-message">{error}</div>}
      </div>
      <footer className="modal-footer">
        <button className="button" onClick={close}>
          取消
        </button>
        <button
          className="button primary"
          disabled={busy}
          onClick={() => void perform(submit)}
        >
          {busy ? <Spinner /> : <Check size={15} />}保存
          {resource ? "新版本" : ""}
        </button>
      </footer>
    </Modal>
  );
}
function Knowledge({
  resources,
  loading,
  notify,
  edit,
  queryText,
  searchCatalog,
}: {
  resources: Resource[];
  loading: boolean;
  notify: (m: string) => void;
  edit: (r: Resource) => void;
  queryText: string;
  searchCatalog: (q: string) => void;
}) {
  const [selected, setSelected] = useState<Resource | null>(null),
    [files, setFiles] = useState<any[]>([]),
    [query, setQuery] = useState(""),
    [result, setResult] = useState<any>(null),
    [busy, setBusy] = useState(false),
    [queryBusy, setQueryBusy] = useState(false),
    [filesLoading, setFilesLoading] = useState(false),
    [filesError, setFilesError] = useState("");
  const upload = useRef<HTMLInputElement>(null);
  const currentLibrary = useRef<Resource | null>(null);
  const selectionVersion = useRef(0),
    fileVersion = useRef(0),
    queryVersion = useRef(0);
  const selectLibrary = (next: Resource | null) => {
    selectionVersion.current++;
    fileVersion.current++;
    queryVersion.current++;
    currentLibrary.current = next;
    setSelected(next);
    setFiles([]);
    setFilesLoading(!!next);
    setFilesError("");
    setQuery("");
    setResult(null);
    setBusy(false);
    setQueryBusy(false);
  };
  useEffect(
    () => () => {
      currentLibrary.current = null;
      selectionVersion.current++;
    },
    [],
  );
  const loadFiles = useCallback(async () => {
    if (selected && currentLibrary.current === selected) {
      const version = ++fileVersion.current;
      try {
        const loaded = await api(
          "/knowledge/files?id=" +
            encodeURIComponent(selected.id) +
            "&revision=" +
            selected.revision,
        );
        if (
          currentLibrary.current === selected &&
          version === fileVersion.current
        ) {
          setFiles(loaded);
          setFilesError("");
        }
      } catch (e) {
        if (
          currentLibrary.current === selected &&
          version === fileVersion.current
        )
          setFilesError((e as Error).message);
      } finally {
        if (
          currentLibrary.current === selected &&
          version === fileVersion.current
        )
          setFilesLoading(false);
      }
    }
  }, [selected]);
  useEffect(() => {
    let alive = true;
    let timer: ReturnType<typeof setTimeout>;
    const poll = async () => {
      await loadFiles();
      if (alive) timer = setTimeout(poll, 5000);
    };
    void poll();
    return () => {
      alive = false;
      clearTimeout(timer);
    };
  }, [loadFiles]);
  if (!selected)
    return (
      <>
        <label className="search-input compact">
          <Search size={16} />
          <input
            aria-label="搜索知识库"
            placeholder="搜索知识库名称或 ID…"
            value={queryText}
            onChange={(e) => searchCatalog(e.target.value)}
          />
        </label>
        <div className="knowledge-grid">
          {loading && (
            <div className="catalog-loading" role="status">
              <Spinner /> 正在读取知识库目录…
            </div>
          )}
          {resources
            .filter((r) => r.kind === "knowledge")
            .map((r) => (
              <button
                className="knowledge-card"
                key={r.id}
                onClick={() => {
                  const version = ++selectionVersion.current;
                  void resourceDetail(r)
                    .then((full) => {
                      if (version === selectionVersion.current)
                        selectLibrary(full);
                    })
                    .catch((e) => {
                      if (version === selectionVersion.current)
                        notify(e.message);
                    });
                }}
              >
                <div className="card-top">
                  <span className="agent-icon color-1">
                    <BookOpen size={24} />
                  </span>
                  <span className="version">v{r.revision}</span>
                </div>
                <h3>{r.spec.name}</h3>
                <p>{r.spec.description || "可供 Agent 绑定的独立知识库"}</p>
                <footer>
                  <span>
                    <Database size={14} />
                    {
                      {
                        local: "本地文本检索",
                        milvus: "Milvus · 向量检索",
                        lightrag: "LightRAG · 图谱检索",
                      }[r.spec.engine as string]
                    }
                  </span>
                  <ChevronRight size={16} />
                </footer>
              </button>
            ))}
        </div>
        <div className="engine-comparison">
          <h3>选择适合资料的检索方式</h3>
          <div>
            <section>
              <span>
                <FileText size={18} />
                文本检索
              </span>
              <p>快速归档和精确关键词查找。上传即可用，不需要 Embedding。</p>
            </section>
            <section>
              <span>
                <Database size={18} />
                向量 RAG
              </span>
              <p>
                Milvus 管理向量，Embedding
                负责语义表示，保留命中文本与原文关系。
              </p>
            </section>
            <section>
              <span>
                <Network size={18} />
                图谱 RAG
              </span>
              <p>
                LightRAG
                提供跨文档实体与关系检索；关系抽取结果仍需回到原文核对。
              </p>
            </section>
          </div>
        </div>
      </>
    );
  return (
    <>
      <div className="library-header">
        <button className="text-button" onClick={() => selectLibrary(null)}>
          <ArrowLeft size={16} />
          全部知识库
        </button>
        <h2>
          {selected.spec.name}
          <span className="version">v{selected.revision}</span>
        </h2>
        <button className="button" onClick={() => edit(selected)}>
          <Settings2 size={15} />
          配置新版本
        </button>
      </div>
      <div className="knowledge-detail">
        <section className="panel">
          <div className="panel-heading">
            <h3>
              资料文件 <span>{files.length}</span>
            </h3>
            <input
              hidden
              type="file"
              multiple
              accept=".txt,.md,.csv,.json,.docx"
              ref={upload}
              onChange={(e) => {
                const list = Array.from(e.target.files || []);
                e.target.value = "";
                void (async () => {
                  setBusy(true);
                  try {
                    for (const file of list) {
                      if (file.size > 1 << 20)
                        throw new Error(file.name + " 超过 1 MiB");
                      await api("/knowledge/upload", {
                        knowledge: {
                          id: selected.id,
                          revision: selected.revision,
                        },
                        name: file.name,
                        source: "upload:" + file.name,
                        content: await base64(file),
                      });
                    }
                    await loadFiles();
                    if (currentLibrary.current === selected)
                      notify("原文件已保存，索引任务已登记。");
                  } catch (e) {
                    if (currentLibrary.current === selected)
                      notify((e as Error).message);
                  } finally {
                    if (currentLibrary.current === selected) setBusy(false);
                  }
                })();
              }}
            />
            <button
              className="button primary"
              disabled={busy}
              onClick={() => upload.current?.click()}
            >
              {busy ? <Spinner /> : <Upload size={15} />}上传资料
            </button>
          </div>
          <p className="field-hint">
            支持 UTF-8 TXT、Markdown、CSV、JSON 和 DOCX 正文；单文件 1 MiB。
          </p>
          {filesError && (
            <p className="inline-warning" role="alert">
              资料列表暂不可用：{filesError}。正在重试。
            </p>
          )}
          {filesLoading ? (
            <div role="status">
              <Spinner /> 正在读取资料列表…
            </div>
          ) : files.length ? (
            <div className="file-list">
              {files.map((f) => (
                <div className="file-row" key={f.id}>
                  <span className="file-symbol">
                    <FileText size={21} />
                  </span>
                  <div>
                    <b>{f.name}</b>
                    <small>{f.document_id.slice(0, 12)} · 原文件已留存</small>
                    {f.error && <p className="error-inline">{f.error}</p>}
                  </div>
                  <Badge state={f.status} />
                  <button
                    className="icon-button"
                    title="下载原文件"
                    aria-label={"下载 " + f.name}
                    onClick={() =>
                      void downloadArtifact(
                        f.artifact_hash,
                        f.name,
                        true,
                      ).catch((e) => notify(e.message))
                    }
                  >
                    <ArrowUpRight size={15} />
                  </button>
                </div>
              ))}
            </div>
          ) : !filesError ? (
            <Empty
              title="从第一份资料开始"
              detail="原文件、正文和来源会一并保留，供检索和回溯使用。"
              action={
                <button
                  className="button"
                  onClick={() => upload.current?.click()}
                >
                  <Upload size={15} />
                  选择文件
                </button>
              }
            />
          ) : null}
        </section>
        <section className="panel retrieval-panel">
          <div className="panel-heading">
            <h3>
              <FlaskConical size={17} />
              检索测试
            </h3>
          </div>
          <p>检查这个知识库实际能找到哪些证据。</p>
          <textarea
            aria-label="检索问题"
            value={query}
            onChange={(e) => {
              queryVersion.current++;
              setQuery(e.target.value);
              setResult(null);
              setQueryBusy(false);
            }}
            placeholder="输入一个关键词或问题…"
          />
          <button
            className="button"
            disabled={queryBusy || !query.trim()}
            onClick={() =>
              void (async () => {
                const version = ++queryVersion.current;
                setQueryBusy(true);
                try {
                  const response = await api("/knowledge/query", {
                    knowledge: {
                      id: selected.id,
                      revision: selected.revision,
                    },
                    query,
                  });
                  if (
                    currentLibrary.current === selected &&
                    version === queryVersion.current
                  )
                    setResult(response);
                } catch (e) {
                  if (
                    currentLibrary.current === selected &&
                    version === queryVersion.current
                  )
                    notify((e as Error).message);
                } finally {
                  if (
                    currentLibrary.current === selected &&
                    version === queryVersion.current
                  )
                    setQueryBusy(false);
                }
              })()
            }
          >
            {queryBusy ? <Spinner /> : <Search size={15} />}检索资料
          </button>
          {result && (
            <div className="retrieval-results">
              {result.hits.map((h: any, i: number) => (
                <article key={i}>
                  <span className="retrieval-rank">{i + 1}</span>
                  <h4>{h.title}</h4>
                  <p>{h.content}</p>
                  <small>{h.source}</small>
                </article>
              ))}
              {!result.hits.length && !result.graph && (
                <p className="inline-empty">没有找到匹配内容。</p>
              )}
              {result.graph && (
                <pre>{JSON.stringify(result.graph, null, 2)}</pre>
              )}
            </div>
          )}
        </section>
      </div>
    </>
  );
}
function Runs({ runs, notify }: { runs: any[]; notify: (m: string) => void }) {
  const selection = useRef(0),
    currentRun = useRef("");
  useEffect(
    () => () => {
      selection.current++;
      currentRun.current = "";
    },
    [],
  );
  const [selected, setSelected] = useState<any>(null),
    [usage, setUsage] = useState<any>(null),
    [calls, setCalls] = useState<any[]>([]),
    [evidence, setEvidence] = useState(""),
    [decision, setDecision] = useState("completed"),
    [receipt, setReceipt] = useState("{}"),
    [callID, setCallID] = useState(""),
    [query, setQuery] = useState(""),
    [stateFilter, setStateFilter] = useState("");
  const visible = runs.filter(
    (r) =>
      (!stateFilter || r.status === stateFilter) &&
      [r.task, r.id, r.snapshot.agent.name]
        .join(" ")
        .toLowerCase()
        .includes(query.toLowerCase().trim()),
  );
  const open = async (id: string) => {
    const version = ++selection.current;
    try {
      const [r, c, u] = await Promise.all([
        api("/runs/" + id),
        api<any[]>("/runs/" + id + "/calls"),
        api("/runs/" + id + "/usage"),
      ]);
      if (version !== selection.current) return;
      if (currentRun.current !== id) {
        setEvidence("");
        setDecision("completed");
        setReceipt("{}");
      }
      currentRun.current = id;
      setSelected(r);
      setCalls(c);
      setUsage(u);
      setCallID(
        c.find((x) => ["unknown", "inflight"].includes(x.status))?.id || "",
      );
    } catch (e) {
      if (version === selection.current) notify((e as Error).message);
    }
  };
  const refreshAfter = async (
    id: string,
    operation: () => Promise<unknown>,
  ) => {
    const version = selection.current;
    try {
      await operation();
      if (version === selection.current && currentRun.current === id)
        await open(id);
    } catch (e) {
      if (version === selection.current) notify((e as Error).message);
    }
  };
  return (
    <>
      <div className="run-filters">
        <label className="search-input">
          <Search size={16} />
          <input
            aria-label="搜索运行记录"
            placeholder="任务、Agent 或 ID"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </label>
        <select
          aria-label="筛选运行状态"
          value={stateFilter}
          onChange={(e) => setStateFilter(e.target.value)}
        >
          <option value="">全部状态</option>
          <option value="running">执行中</option>
          <option value="queued">排队中</option>
          <option value="completed">已完成</option>
          <option value="failed">执行失败</option>
          <option value="waiting_unknown">待核对</option>
          <option value="cancelled">已取消</option>
        </select>
        <small>
          已加载 {runs.length} 项 · 显示 {visible.length} 项
        </small>
      </div>
      <div className="resource-table">
        <div className="run-table-head">
          <span>任务</span>
          <span>Agent</span>
          <span>状态</span>
          <span>创建时间</span>
        </div>
        {visible.length ? (
          visible.map((r) => (
            <button
              key={r.id}
              className="run-table-row"
              onClick={() => void open(r.id)}
            >
              <span>
                <b>{r.task.slice(0, 74)}</b>
                <small>{r.id.slice(0, 16)}</small>
              </span>
              <span>{r.snapshot.agent.name}</span>
              <Badge state={r.status} />
              <small>{date(r.created_at)}</small>
            </button>
          ))
        ) : (
          <Empty
            title={runs.length ? "没有匹配的运行记录" : "执行记录会留在这里"}
            detail={
              runs.length
                ? "调整搜索词或运行状态后再试。"
                : "在 Agent 右侧试运行，或从业务工作台开始一项任务。"
            }
          />
        )}
      </div>
      {selected && (
        <Modal
          title="执行详情"
          close={() => {
            selection.current++;
            currentRun.current = "";
            setSelected(null);
          }}
          wide
        >
          <div className="modal-body">
            <Badge state={selected.status} />
            <p className="field-hint">
              执行器：{selected.engine || "历史任务"}
            </p>
            {usage && (
              <p className="field-hint">
                整项任务（含子任务）模型尝试 {usage.attempts} 次 · 已报告输入{" "}
                {usage.prompt_tokens} / 输出 {usage.completion_tokens} tokens
                {usage.unknown_usage_attempts
                  ? ` · ${usage.unknown_usage_attempts} 次用量未确认，仍占用保守预算`
                  : ""}
                。实际费用以供应商账单为准。
              </p>
            )}
            <div className="run-task">
              <span>任务内容</span>
              <p>{selected.task}</p>
            </div>
            <article className="answer-text">
              <Answer>
                {selected.state.result ||
                  selected.state.error ||
                  "等待执行结果…"}
              </Answer>
            </article>
            <div className="button-row">
              {selected.state.harness_artifact && (
                <button
                  className="button"
                  onClick={() =>
                    void downloadArtifact(
                      selected.state.harness_artifact,
                      `dsh-${selected.engine === "dsh-0.2.0-rc.2-evidence-v1" ? "manifest-" : ""}${selected.id}.json`,
                    ).catch((e) => notify(e.message))
                  }
                >
                  <FileText size={15} />
                  {selected.engine === "dsh-0.2.0-rc.2-evidence-v1"
                    ? "下载执行记录清单"
                    : "下载完整 DSH 执行记录"}
                </button>
              )}
              <button className="button" onClick={() => void open(selected.id)}>
                <RefreshCw size={15} />
                更新详情
              </button>
              {selected.status === "failed" && (
                <button
                  className="button"
                  onClick={() =>
                    void refreshAfter(selected.id, () =>
                      api("/runs/" + selected.id + "/resume", {}),
                    )
                  }
                >
                  从检查点继续
                </button>
              )}
              {[
                "running",
                "queued",
                "waiting_children",
                "waiting_unknown",
              ].includes(selected.status) && (
                <button
                  className="button"
                  onClick={() =>
                    void refreshAfter(selected.id, () =>
                      api("/runs/" + selected.id + "/cancel", {}),
                    )
                  }
                >
                  请求取消
                </button>
              )}
            </div>
            {selected.engine === "dsh-0.2.0-rc.2-evidence-v1" && (
              <p className="muted">
                执行记录按批次保存。下载清单包含当前批次的文件索引、校验值及前序清单入口。
              </p>
            )}
            <details>
              <summary>修订当前任务及未结束子任务的约束</summary>
              <textarea
                value={(selected.constraints || []).join("\n")}
                onChange={(e) =>
                  setSelected({
                    ...selected,
                    constraints: e.target.value.split("\n"),
                  })
                }
              />
              <button
                className="button"
                onClick={() =>
                  void api("/runs/" + selected.id + "/constraints", {
                    values: selected.constraints,
                  })
                    .then(() => notify("约束版本已更新"))
                    .catch((e) => notify(e.message))
                }
              >
                保存约束
              </button>
            </details>
            {selected.status === "waiting_unknown" && (
              <div className="reconcile-form">
                <h3>核对外部执行结果</h3>
                <Field label="待核对调用">
                  <select
                    value={callID}
                    onChange={(e) => setCallID(e.target.value)}
                  >
                    {calls
                      .filter((c) => ["unknown", "inflight"].includes(c.status))
                      .map((c) => (
                        <option key={c.id}>{c.id}</option>
                      ))}
                  </select>
                </Field>
                <Field label="结论">
                  <select
                    value={decision}
                    onChange={(e) => setDecision(e.target.value)}
                  >
                    <option value="completed">已执行，补录真实结果</option>
                    <option value="not_executed">已确认未执行，允许重试</option>
                  </select>
                </Field>
                <Field label="核对依据">
                  <textarea
                    value={evidence}
                    onChange={(e) => setEvidence(e.target.value)}
                  />
                </Field>
                <Field label="回执 JSON">
                  <textarea
                    value={receipt}
                    onChange={(e) => setReceipt(e.target.value)}
                  />
                </Field>
                <button
                  className="button primary"
                  onClick={() =>
                    void refreshAfter(selected.id, () =>
                      api("/runs/" + selected.id + "/reconcile", {
                        call_id: callID,
                        decision,
                        evidence,
                        result: JSON.parse(receipt),
                      }),
                    )
                  }
                >
                  提交核对记录
                </button>
              </div>
            )}
            <details>
              <summary>模型与工具回执 · {calls.length}</summary>
              {calls.map((c) => (
                <pre key={c.id}>{JSON.stringify(c, null, 2)}</pre>
              ))}
            </details>
          </div>
        </Modal>
      )}
    </>
  );
}
function Services({ status }: { status: any }) {
  const [showInactive, setShowInactive] = useState(false);
  const names: Record<string, string> = {
    control: "中台入口",
    registry: "Agent 与资源目录",
    runtime: "Agent Runtime API",
    worker: "执行 Worker",
    toolhub: "ToolHub",
    knowledge: "知识库服务",
    indexer: "知识索引 Worker",
    storage: "持久化存储",
    sandbox: "Sandbox",
    futures: "期货业务入口",
    telemetry: "观测导出",
    sources: "公开资料采集",
  };
  const active = status.instances.filter((i: any) => i.active);
  return (
    <>
      <div className="service-summary">
        <div>
          <Network size={23} />
          <b>{new Set(active.map((i: any) => i.role)).size}</b>
          <span>在线服务类型</span>
        </div>
        <div>
          <CpuIcon />
          <b>{active.filter((i: any) => i.role === "worker").length}</b>
          <span>并行执行实例</span>
        </div>
        <div>
          <ShieldCheck size={23} />
          <b>PostgreSQL</b>
          <span>运行状态与回执持久化</span>
        </div>
      </div>
      <div className="panel">
        <div className="panel-heading">
          <h3>实例状态</h3>
          <label className="checkbox-line">
            <input
              type="checkbox"
              checked={showInactive}
              onChange={(e) => setShowInactive(e.target.checked)}
            />
            显示失联实例
          </label>
        </div>
        <div className="service-table">
          {status.instances
            .filter((i: any) => showInactive || i.active)
            .map((i: any) => (
              <div key={i.id}>
                <span className="resource-small-icon">
                  <Network size={17} />
                </span>
                <span>
                  <b>{names[i.role] || i.role}</b>
                  <small>{i.id}</small>
                </span>
                <span>{i.hostname}</span>
                <code>PID {i.pid}</code>
                <Badge state={i.active ? "在线" : "心跳超时"} />
              </div>
            ))}
        </div>
      </div>
      <p className="field-hint">
        自动刷新，心跳窗口 15
        秒。服务在线表示近期有心跳。Milvus、LightRAG、模型和 Docker
        的可用性需要在对应能力中实际验证。
      </p>
    </>
  );
}
function CpuIcon() {
  return <Terminal size={23} />;
}
function Settings({
  notify,
  saved,
  status,
}: {
  notify: (m: string) => void;
  saved: () => Promise<void>;
  status: any;
}) {
  const [name, setName] = useState("DEEPSEEK_API_KEY"),
    [value, setValue] = useState(""),
    [busy, setBusy] = useState(false);
  return (
    <div className="settings-grid">
      <section className="panel">
        <div className="panel-heading">
          <h3>
            <KeyRound size={18} />
            服务凭证
          </h3>
        </div>
        <p className="field-hint">凭证加密落库，配置页面只使用名称引用。</p>
        <Field label="凭证名称">
          <input value={name} onChange={(e) => setName(e.target.value)} />
        </Field>
        <Field label="API Key 或访问令牌">
          <input
            type="password"
            value={value}
            autoComplete="new-password"
            onChange={(e) => setValue(e.target.value)}
            placeholder="输入后加密保存"
          />
        </Field>
        <button
          className="button primary"
          disabled={busy || !value}
          onClick={() =>
            void (async () => {
              setBusy(true);
              try {
                await api("/credentials", { name, value });
                setValue("");
                await saved();
                notify("凭证已加密保存");
              } catch (e) {
                notify((e as Error).message);
              } finally {
                setBusy(false);
              }
            })()
          }
        >
          {busy ? <Spinner /> : <Check size={15} />}保存凭证
        </button>
      </section>
      <section className="panel">
        <div className="panel-heading">
          <h3>连接说明</h3>
        </div>
        <div className="connection-line">
          <span>DeepSeek</span>
          <Badge state={status.deepseek_configured ? "已配置" : "待配置"} />
        </div>
        <p className="field-hint">
          Agent 编辑器配置对话模型的地址、模型名与凭证引用。知识库中配置独立
          Embedding 服务。
        </p>
        <div className="divider-label">Embedding 起步选型</div>
        <p>
          <b>Qwen3 Embedding 0.6B</b>
          <small className="block">
            中文与多语言检索的轻量候选，默认 1024 维。
          </small>
        </p>
        <p>
          <b>BGE-M3</b>
          <small className="block">
            多语言检索对照方案。当前接口接入其 dense 向量。
          </small>
        </p>
        <p className="field-hint">
          模型未在本机下载或运行。需先配置推理服务，再用自己的资料测召回效果。
        </p>
      </section>
    </div>
  );
}
createRoot(document.getElementById("app")!).render(<Console />);
