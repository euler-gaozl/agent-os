import { useEffect, useRef, useState } from "react";
import {
  api,
  Badge,
  date,
  Field,
  Modal,
  Spinner,
  type Resource,
} from "./shared";

type Finding = { Code: string; Severity: string; Message: string };
type Asset = Resource & {
  enabled: boolean;
  health: string;
  checked_at?: string;
  report: {
    findings?: Finding[];
    latency_ms?: number;
    definition_hash?: string;
  };
};

export function ToolGovernance({ resource }: { resource: Resource }) {
  const [open, setOpen] = useState(false),
    [asset, setAsset] = useState<Asset>(),
    [audit, setAudit] = useState<any[]>([]),
    [files, setFiles] = useState<{ path: string; hash: string }[]>([]),
    [preview, setPreview] = useState<{
      path: string;
      content: string;
      next_offset: number;
      has_more: boolean;
    }>(),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false),
    [reason, setReason] = useState(""),
    [fileBusy, setFileBusy] = useState(false);
  const session = useRef(0),
    loadVersion = useRef(0),
    fileVersion = useRef(0);
  const path = `/toolhub/assets/${encodeURIComponent(resource.kind)}/${encodeURIComponent(resource.id)}/${resource.revision}`;
  const load = async (epoch: number) => {
    const version = ++loadVersion.current;
    const [a, events, bundle] = await Promise.all([
      api<Asset>(path),
      api<any[]>(path + "/audit"),
      api<typeof files>(path + "/files"),
    ]);
    if (epoch !== session.current || version !== loadVersion.current) return;
    setAsset(a);
    setAudit(events);
    setFiles(bundle);
  };
  useEffect(() => {
    if (!open) return;
    const epoch = ++session.current;
    let timer: ReturnType<typeof setTimeout>;
    const poll = async () => {
      try {
        await load(epoch);
      } catch (e) {
        if (session.current === epoch) setError((e as Error).message);
      }
      if (session.current === epoch) timer = setTimeout(poll, 4000);
    };
    void poll();
    return () => {
      session.current++;
      clearTimeout(timer);
    };
  }, [open, path]);
  const act = async (operation: () => Promise<unknown>) => {
    const epoch = session.current;
    setBusy(true);
    setError("");
    try {
      await operation();
      if (session.current === epoch) await load(epoch);
    } catch (e) {
      if (session.current === epoch) setError((e as Error).message);
    } finally {
      if (session.current === epoch) setBusy(false);
    }
  };
  const readFile = async (name: string, offset = 0) => {
    const epoch = session.current,
      version = ++fileVersion.current;
    const prefix = offset && preview?.path === name ? preview.content : "";
    if (!offset) setPreview(undefined);
    setFileBusy(true);
    setError("");
    try {
      const result = await api<any>(
        path + "/file?path=" + encodeURIComponent(name) + "&offset=" + offset,
      );
      if (session.current !== epoch || fileVersion.current !== version) return;
      setPreview({
        path: name,
        ...result,
        content: prefix + result.content,
      });
    } catch (e) {
      if (session.current === epoch && fileVersion.current === version)
        setError((e as Error).message);
    } finally {
      if (session.current === epoch && fileVersion.current === version)
        setFileBusy(false);
    }
  };
  return (
    <>
      <button
        className="button"
        onClick={() => {
          setAsset(undefined);
          setAudit([]);
          setFiles([]);
          setPreview(undefined);
          setReason("");
          setError("");
          setBusy(false);
          setFileBusy(false);
          setOpen(true);
        }}
      >
        检测与启停
      </button>
      {open && (
        <Modal
          title={`${resource.spec.name || resource.id} · v${resource.revision}`}
          close={() => {
            session.current++;
            fileVersion.current++;
            setOpen(false);
          }}
          wide
        >
          <div className="modal-body form-stack">
            {error && (
              <div className="inline-warning" role="alert">
                {error}
              </div>
            )}
            {!asset ? (
              <Spinner />
            ) : (
              <>
                <div className="button-row">
                  <Badge state={asset.health} />
                  <span>{asset.enabled ? "已启用" : "未启用"}</span>
                  <small>
                    最近检查：
                    {asset.checked_at
                      ? date(asset.checked_at)
                      : "尚未检查"} · {asset.report.latency_ms || 0} ms
                  </small>
                </div>
                <p>
                  {resource.kind === "connector"
                    ? "检查协议握手、工具发现和定义变化。验活不会调用业务工具；检查超过 5 分钟会阻止新调用。"
                    : "检查定义和包内容。静态扫描无法证明 Skill 安全，启用前仍需审阅全部指令及引用文件。"}
                </p>
                {(asset.report.findings || []).map((f, i) => (
                  <div className="inline-warning" key={i}>
                    <b>
                      {f.Severity === "error" ? "阻断" : "待审阅"} · {f.Code}
                    </b>
                    <p>{f.Message}</p>
                  </div>
                ))}
                <div className="button-row">
                  <button
                    className="button"
                    disabled={busy}
                    onClick={() => void act(() => api(path + "/check", {}))}
                  >
                    {busy ? <Spinner /> : "重新检测 / 验活"}
                  </button>
                </div>
                <Field label="启停原因（记入审计记录）">
                  <input
                    value={reason}
                    onChange={(e) => setReason(e.target.value)}
                    placeholder="例如：已核对来源、指令和工具权限"
                    maxLength={2000}
                  />
                </Field>
                <button
                  className="button primary"
                  disabled={
                    busy ||
                    !reason.trim() ||
                    (!asset.enabled && asset.health !== "healthy")
                  }
                  onClick={() =>
                    void act(() =>
                      api(path + "/activation", {
                        enabled: !asset.enabled,
                        reason,
                      }),
                    )
                  }
                >
                  {asset.enabled ? "停用此版本" : "确认审阅并启用此版本"}
                </button>
                {files.length > 0 && (
                  <>
                    <h3>Skill 包内容</h3>
                    {files.map((f) => (
                      <button
                        className="button"
                        key={f.path}
                        onClick={() => void readFile(f.path)}
                      >
                        {f.path} · SHA256 {f.hash.slice(0, 12)}
                      </button>
                    ))}
                    {fileBusy && (
                      <div role="status">
                        <Spinner /> 正在读取文件…
                      </div>
                    )}
                    {preview && (
                      <>
                        <b>{preview.path}</b>
                        <pre
                          style={{
                            whiteSpace: "pre-wrap",
                            maxHeight: 320,
                            overflow: "auto",
                          }}
                        >
                          {preview.content}
                        </pre>
                        {preview.has_more && (
                          <button
                            className="button"
                            disabled={fileBusy}
                            onClick={() =>
                              void readFile(preview.path, preview.next_offset)
                            }
                          >
                            继续读取
                          </button>
                        )}
                      </>
                    )}
                  </>
                )}
                <details className="audit-details">
                  <summary>审计记录 · 已加载 {audit.length} 项</summary>
                  <div className="event-list">
                    {[...audit].reverse().map((e) => (
                      <div key={e.seq}>
                        <b>{e.action}</b>
                        <small>
                          {" "}
                          {date(e.created_at)} · {e.actor}
                        </small>
                        {e.details.reason && <p>{e.details.reason}</p>}
                      </div>
                    ))}
                  </div>
                </details>
              </>
            )}
          </div>
        </Modal>
      )}
    </>
  );
}
