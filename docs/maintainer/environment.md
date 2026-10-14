# 下载与接手环境

主仓：[euler-gaozl/agent-os](https://github.com/euler-gaozl/agent-os/tree/feat/end-to-end-delivery)。**本次交接入口位于 `feat/end-to-end-delivery`，不要假设默认 main 含所有最新增量。** 所有项目 URL、分支和已核对 SHA 在 [repositories.json](repositories.json)。15 仓公开，读取源码无需原所有者的 GitHub Token；提交推送用接手者自己的权限或 PR。

## 新电脑先取得可审查的源码

以下仅克隆源码，不安装、不启动、不读取私人配置。默认使用原所有者指定的 D 盘布局；若朋友没有 D 盘，应先明确一个自己的固定工作根目录，不能在原电脑擅改路径。已有目录时脚本直接停止，不覆盖或 reset。

```powershell
$repoRoot = 'D:\workspace\agent-platform\repos'
New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
$integration = Join-Path $repoRoot 'agent-os'
if (Test-Path -LiteralPath $integration) { throw '目录已存在，请先核对其 remote/status，不要覆盖。' }
git clone --branch feat/end-to-end-delivery https://github.com/euler-gaozl/agent-os.git $integration
if ($LASTEXITCODE -ne 0) { throw '主仓克隆失败' }
$inventory = Get-Content -LiteralPath (Join-Path $integration 'docs/maintainer/repositories.json') -Raw | ConvertFrom-Json
foreach ($repo in $inventory.repositories) {
    if ($repo.name -eq 'agent-os') { continue }
    $target = Join-Path $repoRoot $repo.name
    if (Test-Path -LiteralPath $target) { throw "目录已存在：$target，请人工核对" }
    git clone --branch $repo.branch $repo.clone_url $target
    if ($LASTEXITCODE -ne 0) { throw "克隆失败：$($repo.name)" }
    git -C $target checkout --detach $repo.source_head_at_audit
    if ($LASTEXITCODE -ne 0) { throw "固定交接源码失败：$($repo.name)" }
}
```

服务仓检出交接源码基线，方便准确审查；开始修改前从基线建立自己的工作分支。**克隆 HEAD 不是安装指令**：若要复现原服务组合，先按 `deploy/service-sources.json` / installed snapshot 选择相应提交，并通过受管发布流程操作。主仓保留交接分支最新提交，以免固定到交接前 SHA 后丢掉这些文件；该区别在 JSON 中有说明。

不要执行任意 `go get -u`、统一更新 lockfile 或移除固定 Owner 包。Go `go.mod` 和 JS `package.json` / lockfile 才是各仓依赖要求。

## 工具与不花钱的首轮验证

原电脑使用 PowerShell 7.6、Go 1.27.2、Node 24.19、pnpm 11.25；这是观测版本，不把所有版本数字当最低要求。先读目标仓 AGENTS/README、go.mod/package.json 和测试说明。

- Go Owner：适当执行 `go test ./...`、`go vet ./...`、构建；需数据库的测试必须使用一次性隔离 PostgreSQL。没有 `TEST_DATABASE_URL` 时关注 skip，不能宣称数据库测试通过。
- Console/Futures Web：按实际 scripts 执行固定依赖安装、测试和构建；不要凭本文件猜脚本名。
- Harness：固定官方来源，按其 README 构建与验证包；夹具测试不消费真实模型，也不证明官方模型业务成功。
- 原电脑证据不随仓库传输。缺少真实资料时先做脱敏夹具、协议与恢复测试，结果明确标记；真实研究验收仍待原环境或经过选择的数据交接。

提交前检查 diff 和凭证扫描。15 仓 Actions 保持禁用，不为“验证提交”开启 CI；最终整体验收才使用一次预算明确的汇总 CI。

## 原电脑：先只读核对

```powershell
git -C 'D:\workspace\agent-platform\repos\agent-os' status --short
& 'D:\workspace\agent-platform\ops\Platform.ps1' status
& 'D:\workspace\agent-platform\ops\Platform.ps1' doctor
```

先阅读命令输出及脚本，不在未知 pending 状态下强行启动、更新、回滚。正式入口为 `ops/Platform.ps1`，转发到主仓 `scripts/Platform.ps1`。不同维护动作共享全局锁，等待上一项结束再执行下一项。不要并行跑安装、配置事务、备份与恢复。

本机布局：

```text
D:\workspace\agent-platform\
  repos\          15 个源码仓库
  local\
    data\postgres\  原正式数据库，不重新 initdb
    releases\       format2 catalog / 固定发布 manifest / Harness 包
    evidence\       私有验收输入输出
    ...             配置、运行状态、日志、备份等，按实际布局核对
  ops\            机器维护入口、证据指针与辅助脚本
```

`local/releases/current.json` 以 role.current.manifest 指向固定发布；读取 manifest.provenance 和 contract，不用文件夹名猜安装版本。工具通常在 `D:\workspace\.tools`；Node 也有固定受管发布。`ops/*.path` 是证据目录指针，不是可以上传的资源包。

## 新 Windows 的真实限制

当前 Windows 维护链主要基于已有 layout、受保护配置和 catalog；[`cmd/provision` 的部署流程](../fresh-deployment-provision.md) 是 Linux 路线。不能把 Linux 测试或早期 `Initialize-Local.ps1` 当作“全新 Windows 一键重建当前 12 服务”的证明。

新机器若需要运行完整平台，要补齐/验收 `task:fresh-windows-bootstrap`：数据库初始化、各 Owner 迁移/受限身份、固定发布登记、Harness 包、凭证录入及冷启动。不要调用旧 `Start -Migrate` 重建共享迁移，不覆盖原机数据库。可以先在朋友机器完成源码修改和隔离测试，回原机受管安装与真实验收。

Windows DPAPI 凭证绑定用户/机器上下文；直接复制加密文件不保证可解密。朋友需要真实调用时由所有者安全配置供应商凭证，不从聊天、日志或旧 Git 记录提取 Key。提供数据库/证据资料需要另行选择与脱敏；此次交接没有授权公开原始私人资料。

## 真正要恢复的业务输入

本机 Registry 当前研究 Agent revision 17、Skill revision 6 和研究输入见 [状态快照](current-state.md)；不等同于静态 packs 种子。原环境通过只读 API/证据检查完整版本；新机器需选取可分享的资源配置与资料，不在公共仓补传整库。

交接前没有悬空的功能代码修改；只读定位停在模型轮次分配/报告质量。先从 [backlog.md](backlog.md) 第一项继续，保留完整目标。旧聊天 Goal 会暂停；接手者在自己的聊天按同一范围设新 Goal，原聊天权限、历史工具会话和记忆不会自动迁移。
