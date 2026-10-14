# 本机公开来源域名配置

`Sources` 只访问运维配置的精确 HTTPS 主机。默认目录不代表已接入研究所需的行业来源；白名单不证明网页真实、数据准确或具备转载授权。服务仍逐次校验公网地址、禁止重定向和敏感 URL 参数，不因新增主机放开私网访问。

在标准维护窗口，先停止已登记部署中的 Console、Futures 和 Worker，确认无执行中任务，再运行：

```powershell
./scripts/Set-SourceHosts.ps1 -Hosts @('www.stats.gov.cn','www.gov.cn')
```

参数是完整目标集合，会替换当前集合。只接受 1–32 个不重复的小写 DNS 主机名；不接受 URL、通配符、端口、IP 和空集合。空集合可能使服务回落默认目录，因此明确拒绝。配置后用标准 start 恢复原入口和 Worker 数量，再执行 doctor。

该命令复用既有服务发布事务，只修改 Sources 的 `SOURCE_ALLOWED_HOSTS`，不修改代码、数据库或其他服务。原/新配置用 DPAPI 保存；先登记 pending，再停目标服务、替换配置、按实际进程校验就绪并提交。异常时恢复原配置；维护进程被中断后使用 `Platform.ps1 release-recover -Service sources`，恢复前仍须停止入口和 Worker。未知配置漂移保持拒绝，不覆盖手工改动。

`scripts/Test-MCPConfiguration.ps1` 保留 Runtime/ToolHub 原场景并加入 Sources。2026-10-14 的 74 项检查通过：真实 Windows 夹具进程、DPAPI、隔离 PostgreSQL 空闲检查、配置漂移、就绪失败、维护子进程退出与恢复、非目标实例不变。证据由 `ops/source-hosts-checks.path` 指向；夹具验证不等于正式来源采集成功。独立静态评审未发现阻断，评审未代跑测试。
