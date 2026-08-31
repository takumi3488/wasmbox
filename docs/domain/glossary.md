# Domain Glossary

## Aggregate

### Workload

ContainerまたはWasmの実行単位。nameは一意、内部IDはUUID。

- `WorkloadSpec` enum
  - `.container(ContainerSpec)`
  - `.wasm(WasmSpec)`
- 共通設定: name / source / execution / env / args / ports / health / restart / retention / tags
- `DesiredState = Running | Stopped`
- `RuntimeState` は最新Run・health・runtime状態から導出
- `draftRevision` / `activeRevision` を分離

### Run

1回のprocess実行。1 Run = 1 process。

- ID: UUID
- runtime名: `wasmbox-<workloadUUID>-<runUUID>`
- `trigger = Manual | Scheduled | Restart | RollingUpdate | Resume`
- `restartChainID` / `attemptIndex`
- resolved artifact ID/hashを保存
- `Skipped` Runは scheduled time / trigger type / reason / resolved sourceを保持

状態:

- `Pending`
- `Starting`
- `Running`
- `Succeeded`
- `Failed`
- `Skipped`
- `Terminating`
- `Terminated`

終了理由:

- `StoppedByUser`
- `TerminatedByAppQuit`
- abnormal kill

成功判定:

- exit code 0 のみ `Succeeded`
- 非0は `Failed`
- health checkは成功条件に含めない

### Artifact

実行対象の実体。sourceとresolved内容を分離。

- Container: OCI image reference
- Wasm: local path / HTTPS URL
- `Pinned`: digest/hash固定
- `RefreshOnStart`: 起動前に再解決・再取得
- Runはresolved artifact ID/hashを参照

### Schedule

定期実行設定。

- 5フィールドcronのみ
- macOS現在のローカルタイムゾーンを都度参照
- DST消失時刻はskip、重複時刻は1回のみ
- GUI起動中のみ実行
- missed runは`SchedulerMissedWindow`へ集約

## Value Object

### RuntimeKind

- `AppleContainer`
- `Wasmtime`

### ArtifactUpdatePolicy

- `Pinned`
- `RefreshOnStart`

### ExecutionMode

- `Once`
- `Scheduled`
- `AlwaysOn`

### RestartPolicy

- 常時起動はdesired state
- process終了・health check失敗で自動再起動
- `maxRestartAttempts`超過後 `Failed`
- `stableFor`超過でrestart counter reset（既定5分）

### HealthCheck

- Container: command / HTTP / TCP
- Wasm: HTTP / TCP
- 初期値: `Unknown`
- 未設定: `NotConfigured`
- 連続失敗回数・連続成功回数を設定可能
- `startPeriod` / `unhealthyGracePeriod`を設定可能

### HealthStatus

- `Unknown`
- `Healthy`
- `Unhealthy`
- `NotConfigured`

### PortMapping

- `guestPort -> hostPort`
- `hostPort`未指定なら空きport自動割当
- 固定hostPortは全Workloadで一意
- 固定hostPortかつ`maxConcurrentRuns > 1`は`InvalidConfig`

### EnvironmentVariable

- `plain`: 設定へ保存
- `secret`: macOS Keychainへ保存
- host環境変数は継承しない

### Mount

- Container: host path -> container path
- Wasm: WASI preopen directory
- `readOnly | readWrite`
- host path不存在は起動失敗

### MetricsSample

- CPU / memoryのみ
- 5秒取得
- 1分集計
- 24時間保持

## Domain Service

### RuntimeAdapter

runtime差を閉じ込める。

- `start`
- `stop`
- `inspect`
- `logs`
- `metrics`
- `update`

error分類:

- `Unavailable`
- `Invalid`
- `NotFound`
- `Conflict`
- `Timeout`
- `Unknown`

### ArtifactResolver

- OCI image tagをdigestへ解決
- Wasm URLをdownloadしてSHA-256解決
- cacheとexpected hashを検証

### Scheduler

- cron評価
- missed window記録
- `maxConcurrentRuns`判定

### HealthMonitor

- health check実行
- 連続成功/失敗判定
- startPeriod / grace period適用

### RestartSupervisor

- restart chain管理
- backoff
- max attempts判定
- stableFor reset

## Event

永続化するRun状態event:

- `RunCreated`
- `Started`
- `Exited`
- `Failed`
- `HealthChanged`
- `RestartScheduled`
- `Skipped`
- `Orphaned`

揮発event:

- UI通知
- log stream
- metrics更新

## Derived Workload Status

`DesiredState` + 最新Run + health + runtime状態から導出。

- `Stopped`
- `Starting`
- `Running`
- `Unhealthy`
- `Restarting`
- `Failed`
- `Blocked`
- `InvalidConfig`
- `RuntimeUnavailable`
- `UpdateRequiresRestart`
- `Updating`
- `UpdateFailed`
- `Orphaned`
