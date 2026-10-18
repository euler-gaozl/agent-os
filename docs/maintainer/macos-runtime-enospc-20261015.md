# Mac Runtime Owner ENOSPC 增量（2026-10-15）

环境：维护者独立 macOS 15.3（24D2059）/arm64，Go 1.27.2、PostgreSQL 18.6。1 项真实故障测试通过（1.21 秒，非 race，零 skip）。原始证据留在本 Mac 的 `local/evidence/runtime-enospc-e0b40ab2f466dcff6c4cd91ad0d3f4d2`；这不是原 Windows 数据或验收。详细场景和限制见 [Runtime Owner 验收说明](../runtime-enospc-macos-20261015.md)。

note_save 的 INSERT documents 与 EndModel 的 UPDATE calls 分别得到 53100，并有各自新日志窗口内同后端 PID 的目标 SQL。释放唯一填充文件后重启相同 PGDATA；任何重试前，10 张 Owner 表完整行摘要和两运行 usage 不变。失败笔记无文档/回执/审计/事件，未完成模型保持 inflight、一次 unknown usage 与预算预留。自然租约到期后 fence 提高，旧 owner 被拒，已完成回执重放不重复合成结果；同 operation 笔记重试幂等。

## 源码与执行边界

- 实际执行 Runtime 基线 `e6c8b935e5e0a00e6bfab14aa099eb8aaf0436d9` 加唯一未跟踪测试 `runtime/disk_full_darwin_test.go`，文件 SHA-256 `985da500f2d93462f564536fdfaf8597b897feb704f914f8f6e15ac6f52aece5`；不是干净已提交测试版本。
- 控制器基线为主仓 `94ab2dc976c491aff9dbd8ff8fd1bee37750252f`，实际执行控制器 SHA-256 `c84fcb0335d642df59ebc6bc98df139f839c64229cae24b75091298a0be97ac9`。
- 记录时 Runtime HEAD 为 `c4d1785dbbb0445f57f1bd5f5b2de079ee9c43fe`。后续提交归档或 clean-commit 来源门调整，不自动成为新版本重复故障通过证据。
- 固定 vendor 编译；Owner 迁移创建新库与 NOLOGIN 测试角色，连接后 SET ROLE；不是独立应用账号登录验证。模型回执是合成协议数据，archive 为内存夹具，真实供应商调用 0。
- 没有修改生产逻辑、旧任务快照、模型预算或固定协议；没有独立 Runtime/Worker/Node/Storage 进程，不证明受管发布、真实业务或 UI。

## 证据摘要

下列 A 的 usage（prompt/completion/cached/accounted = 200/50/120/250）全部来自合成响应；B 的 accounted_tokens=393970 是未知尝试的保守预算预留，不是供应商实际用量或费用。B 的实耗字段为 0 不代表已知免费。本轮真实供应商调用为 0。

```json
{
  "status": "passed_limited_owner_transaction_scope",
  "outcome": "1 项真实故障测试通过（1.21 秒，非 race，零 skip）",
  "environment_id": "environment:maintainer-macos",
  "os": "macOS 15.3 (24D2059)",
  "cpu": "arm64",
  "evidence": "local/evidence/runtime-enospc-e0b40ab2f466dcff6c4cd91ad0d3f4d2",
  "executed_runtime_base": "e6c8b935e5e0a00e6bfab14aa099eb8aaf0436d9",
  "test_sha256": "985da500f2d93462f564536fdfaf8597b897feb704f914f8f6e15ac6f52aece5",
  "executed_controller_sha256": "c84fcb0335d642df59ebc6bc98df139f839c64229cae24b75091298a0be97ac9",
  "archival_runtime_commit": "c4d1785dbbb0445f57f1bd5f5b2de079ee9c43fe",
  "toolchain": {
    "go": "go version go1.27.2 darwin/arm64",
    "postgres": "postgres (PostgreSQL) 18.6",
    "go_mod_sha256": "06faf7a3b475306470264b9908c70b2597e596c9b4eb9e8bfab3408622e028c7",
    "vendor_modules_sha256": "c0744357d9a6e20a6185978a3afdd3cb2edbff8a6d731d9da60a63b458b726fe"
  },
  "historical_attempts": [
    {
      "evidence": "local/evidence/runtime-enospc-9c3bd97247d6e7bc83edfdf79483781d",
      "status": "failed_before_target_note_sql",
      "duration_seconds": 2.78,
      "test_sha256": "e4c1425c2aadc6aa9cdc598486ea52ef9f007b7dc5ca6c4167d8f32622cd0509",
      "controller_sha256": "a443e7f56450fb56f319e733fda27fbc0f7e9b8b5fd895bcd25ef8e7de77f35f",
      "filler_bytes": 448069632,
      "available_blocks": 0,
      "note_sqlstate": "",
      "target_statement_matched": false,
      "cleanup": {
        "runtime_test_stopped": true,
        "postgres_stopped": true,
        "image_detached": true,
        "fixture_removed": true,
        "passed": false,
        "interrupted": false,
        "failure": "test failed (1; timeout=false)",
        "evidence_errors": [],
        "scope": "Only this newly created image, postmaster and Runtime Owner test; no Storage or existing clusters/volumes"
      },
      "cleanup_observation": {
        "at": "2026-10-15T01:48:59.777Z",
        "postgres_pid": 8793,
        "postgres_pid_absent": true,
        "image_absent": true,
        "fixture_root_absent": true,
        "runtime_test_absence": "controller-owned PID check recorded in cleanup.json"
      },
      "cause": "Source-contract diagnosis: 128 KiB hex note exceeded note_save.content maxLength=20000; original evidence did not preserve the raw non-PgError text, so this is source-based attribution, not a quoted log error.",
      "evidence_sha256": {
        "inputs.json": "491035439116c32840ae42196880c7af266a71aabdddf9e75851f923ed102699",
        "fill.json": "891e3614df566bcfee31b28423c4e1fa51eba92fa9256ca75c61894c06131117",
        "note-fault.json": "2e05618a0de05aa34afb1ae264861f20394d1cf161d8bff351bc27d9227c453e",
        "cleanup.json": "53a88b07ed056489a95cf61dce6dcfeb40a042ff4911963c5cf11b5d06081881",
        "cleanup-observation.json": "cd9f93edbbf7c482d20ada02dd77254cc12e8c573ba5bf5cb10b95965a2f86de",
        "test.log": "a7e1db2b6782fba960717a2b2e9f7f67c66c1e5ab412000cfcc756d6c270efb4"
      }
    }
  ],
  "build": {
    "runtime_source_base_commit": "e6c8b935e5e0a00e6bfab14aa099eb8aaf0436d9",
    "test_sha256": "985da500f2d93462f564536fdfaf8597b897feb704f914f8f6e15ac6f52aece5",
    "controller_sha256": "c84fcb0335d642df59ebc6bc98df139f839c64229cae24b75091298a0be97ac9",
    "go_path": "local/toolchains/go1.27.2/bin/go",
    "test_binary_sha256": "8be221564fd43612c20c72f299a226ef6f8252b5ee4ac19759bd934b600bc338",
    "scope": "Runtime Owner in-process transaction test; synthetic native receipts, no Worker/Harness/Storage or real provider"
  },
  "fill": {
    "available_blocks": 0,
    "available_bytes": 0,
    "fill_stages": [
      {
        "available_blocks": 80,
        "available_bytes": 327680,
        "bytes_written": 447741952,
        "write_enospc": true,
        "write_size": 1048576
      },
      {
        "available_blocks": 0,
        "available_bytes": 0,
        "bytes_written": 327680,
        "write_enospc": true,
        "write_size": 4096
      },
      {
        "available_blocks": 0,
        "available_bytes": 0,
        "bytes_written": 0,
        "write_enospc": true,
        "write_size": 1
      }
    ],
    "filler_bytes": 448069632,
    "initial_postmaster_pid": 9139,
    "volume_capacity_bytes": 535781376
  },
  "note_fault": {
    "error_type": "*pgconn.PgError",
    "log_offset_before": 1355,
    "operation_failed": true,
    "postgres_disk_errors": [
      "2026-10-15 09:51:27.196 CST [9156] ERROR:  53100: could not extend file \"base/16386/16398\": No space left on device",
      "2026-10-15 09:51:27.196 CST [9156] STATEMENT:  INSERT INTO documents(id,kind,title,content,source,metadata,supersedes,scope,valid_until) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)"
    ],
    "sqlstate": "53100",
    "target_statement_matched": true
  },
  "model_fault": {
    "error_type": "*pgconn.PgError",
    "log_offset_before": 1777,
    "operation_failed": true,
    "postgres_disk_errors": [
      "2026-10-15 09:51:27.222 CST [9157] ERROR:  53100: could not extend file \"base/16386/16493\": No space left on device",
      "2026-10-15 09:51:27.222 CST [9157] STATEMENT:  UPDATE calls SET status=$3,response=$4,error=$5,updated_at=now() WHERE id=$1 AND attempt=$2 AND fence=$6"
    ],
    "sqlstate": "53100",
    "target_statement_matched": true
  },
  "before_retry": {
    "all_committed_rows_unchanged": true,
    "failed_note_audits": 0,
    "failed_note_calls": 0,
    "failed_note_documents": 0,
    "failed_note_events": 0,
    "pending_model_attempt_status": "inflight",
    "pending_model_call_status": "inflight",
    "pending_model_response_absent": true,
    "recovered_postmaster_pid": 9168,
    "same_cluster_system_identifier": true,
    "table_sha256": {
      "calls": "0c1f0bf4622adda2c0a6370b24d51eeb2a4e2458ed4c20251a0c24afd655c939",
      "documents": "8a2f7664fb3d0d262ebdb009499f913d2c69ba237b346d9b50086541159a9fce",
      "events": "4c9ebcb44f24f349b225d517ead61a41be972d7c9ed3b44f59c498fc3c0e11f6",
      "harness_archives": "d04c538a63030c26ab13cdc8b3854669472faeadf3bbd433eeff69a273ab042e",
      "harness_exchanges": "9ab2ab5e48dc88f8ec107d4b1d415c2a865b575996abac7de519c995c174989c",
      "model_attempts": "4c9eedade2f892b64fbca30e313042e3b06eae42add1e502abb15143e9f8ec77",
      "note_audits": "e629e923706f8f7fe6090fbc6573cda47fa9cfba5933200240e1572bcccd60cf",
      "note_roots": "332b4329f2a3ef34b3ca46ec366eaf47eb668548395964b931777a457b9e1f36",
      "note_versions": "d7ba71484b74580f78d16e0187e7f4e01df9d61879e86ee399e12e3ca8f2b33a",
      "runs": "27fc6c7cd75c7ee6f9adc78009fa48481e309604ba2dbcefd00ee1cf6f5be856"
    },
    "usage_a": {
      "root_id": "a0d9f246cc27fbb89852fdb545a75f97",
      "attempts": 1,
      "unknown_usage_attempts": 0,
      "prompt_tokens": 200,
      "completion_tokens": 50,
      "cached_prompt_tokens": 120,
      "accounted_tokens": 250,
      "max_attempts": 12,
      "token_budget": 0
    },
    "usage_b": {
      "root_id": "4aafcface5e28de5cd6a647c9811a232",
      "attempts": 1,
      "unknown_usage_attempts": 1,
      "prompt_tokens": 0,
      "completion_tokens": 0,
      "cached_prompt_tokens": 0,
      "accounted_tokens": 393970,
      "max_attempts": 12,
      "token_budget": 0
    }
  },
  "result": {
    "documents": 2,
    "end_model_sqlstate": "53100",
    "model_attempts": 2,
    "model_completed_events": 1,
    "natural_fence_after": 2,
    "natural_fence_before": 1,
    "note_audits": 2,
    "note_roots": 2,
    "note_sqlstate": "53100",
    "note_versions": 2,
    "passed": true,
    "pre_retry_rows_unchanged": true,
    "real_enospc": true,
    "real_provider_calls": 0,
    "same_pgdata_recovery": true,
    "scope": "Mac Runtime Owner transactions and NOLOGIN SET ROLE pools; archive is in memory; excludes independent Runtime/Worker processes, Node, real Storage, paid providers, Windows, host-disk exhaustion, Compact and remote tool receipts",
    "synthetic_completed_outcomes": 1,
    "tool_calls": 2,
    "tool_completed_events": 2,
    "unknown_attempts_preserved": 1
  },
  "cleanup": {
    "runtime_test_stopped": true,
    "postgres_stopped": true,
    "image_detached": true,
    "fixture_removed": true,
    "passed": true,
    "interrupted": false,
    "failure": null,
    "evidence_errors": [],
    "scope": "Only this newly created image, postmaster and Runtime Owner test; no Storage or existing clusters/volumes"
  },
  "cleanup_observation": {
    "at": "2026-10-15T01:52:35.711Z",
    "initial_postgres_pid": 9139,
    "initial_postgres_pid_absent": true,
    "recovered_postgres_pid": 9168,
    "recovered_postgres_pid_absent": true,
    "image_absent": true,
    "fixture_root_absent": true,
    "runtime_test_absence": "controller-owned PID check recorded in cleanup.json"
  },
  "evidence_sha256": {
    "inputs.json": "872414632d147bf08391b8a19ae238f94b6c5ae41a0dfb06223b91a31662d273",
    "build.json": "0ac28f84cc6e7a230e91864597d90cf01b6c36f43bcf42c42bc54a2125311099",
    "commands.json": "a377443fae528d86871d3ab70e24f3c968ac12de02ded17db18edb96f9f3fcc6",
    "cleanup.json": "ea33d360224eba7e14f76aafd0c2b9cfac5014f3fd4cf8b9cd2b3f34b9b99149",
    "cleanup-observation.json": "0b323a4afd8b15a180995763b0b23ba95f13239e14fb2df728630ea37dd4e107",
    "runtime-commit.json": "1d6ee0ef638cd571caab2860afd3a4e2ef384a42853f55951722fbfdfaf27b66",
    "baseline.json": "2256b257074b382d76380febf73cd5d53505dba418d7d3b93919e9c6e894dd1b",
    "fill.json": "707bef1f28bb9d14294ae3ab4156d9d8d079c952e46b7390f908249a838edcc6",
    "note-fault.json": "884986b21d8701918a947708ca4c7866c829bd8f3142c1c975dd9be432d78448",
    "model-fault.json": "1f2fe3544d87f45cba3778108fd1af1cff9b8429761ce3cddf89fdedb570fb8a",
    "before-retry.json": "9ce2ca89e65f5f2368bda6b7e9bcae19a467541af2497ac93e8cd118ca2a9a40",
    "result.json": "82658df042b2cf6b4aea1013e710c6c43f536df9f585db452efd9f93c4a51b71",
    "test.log": "63196714fce892b10967b22b2232cbe96b755869decb1e9f59aaf47ffbb48abe",
    "postgres-version.log": "66cbaae4250f039f92200da1428bbd0f3f0850da18716bb1ce501a178c259711"
  }
}
```

## 评审、结果与保留范围

准备阶段独立静态审查只识别了底层文档 1,000,000 字节限制，漏掉更早的 note_save.content 20,000 字符工具合约；首轮 128 KiB 笔记因此在目标 SQL 前被拒，2.78 秒失败及完整清理保留。该失败属于夹具缺陷与静态漏检，不是生产逻辑缺陷或事务验收通过。修正后笔记使用 16,384 个 ASCII 字符，填盘前对同一 Invocation 运行现有 authorize 校验；模型原响应维持 2 MiB，没有放宽生产限额。每条 SQL 故障独立归因，记录同后端 PID 的 ERROR 53100 和目标 STATEMENT。初版 e4c1425c 通过 Owner overlay 编译与 go vet，但其首轮故障执行失败。修正的 985da500 通过本次控制器实际编译及根代理 go vet；独立静态 delta 审查完成。编译和审查不替代上面的实际执行状态。回执重放采用 JSON 语义比较；恢复前十表摘要实际一致，不泛称原始供应商回执逐字节比较。本次基线 valid_until/supersedes 均为 NULL，不覆盖非空有效期、改版或撤回生命周期。

只推进 P2 的 Runtime Owner 笔记/本地工具回执故障覆盖移交，并新增旧测试缺少的 model_attempts/usage 断言。此前 [Storage 切片](../storage-enospc-macos-20261015.md)独立留存；两者不能组合宣称一次完整 Runtime/Storage 故障联调。旧 `internal/platform/disk_full_test.go` 与 `storage-faults.yml` 继续保留。P0–P5/P2.5、W01–W14 状态未关闭：Compact、完整笔记生命周期、独立服务/Worker/DSH、全平台资源、Windows DPAPI/受管发布/原库恢复、真实研究质量和完整浏览器流程仍待相应验收。

不运行 Actions、不推送、不读取或提交凭证/私人原文；新配置与测试库由隔离控制器限定清理。旧 Windows current-state、历史安装与此前 Mac 失败/通过证据未覆盖。
