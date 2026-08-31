# wasmbox Specification

## 1. Purpose

wasmboxはlocal macOS上でContainerとWasm workloadを管理するGUIアプリ。

v1で提供する機能：

- Container / Wasm workloadの設定
- 1回実行 / 定期実行 / 常時起動
- health check
- 実行引数・環境変数
- port mapping
- volume / WASI preopen
- restart / rolling update
- Run履歴・log・metrics
- draft設定 / apply
- import / export
- tagによる一括操作

非対象：

- remote host
- SSH
- Kubernetes
- cloud environment
- LaunchAgent / daemon常駐
- Docker / Podman adapter
- WasmKit runtime
- named volume
- Wasm内部export health check
- revision履歴からの復元
- event sourcing全量
- network / disk metrics
- global同時実行上限
- cron秒精度
- cron拡張構文

## 2. Scope

### 2.1 Execution host

- v1の`ExecutionHost`は`LocalMac`のみ。
- schedulerはGUI起動中のみ実行する。
- GUI未起動中の定期実行は追走しない。

### 2.2 Runtime

Container runtime：

- Apple `container`
- Apple silicon
- macOS 26以降
- OCI image対応

Wasm runtime：

- Wasmtime C APIをSwift組込み
- external `wasmtime` CLIへ依存しない
- WASI socket許可によりguest自身がlisten可能

Runtime差分：

- `RuntimeAdapter`へ閉じ込める
- v1でDocker / Podman / WasmKit adapterは持たない

### 2.3 Runtime requirements

起動時検査：

- runtime存在
- runtime version
- Apple `container` system service起動状態
- 権限
- runtime接続

Version policy：

- 最小versionのみ定義
- 最小version未満は`RuntimeUnavailable`
- 未検証versionでも警告なしで許可

未導入時：

- appはruntime installerを実行しない
- 導入手順を表示する
- system service起動を自動実行しない

## 3. Domain model

### 3.1 Aggregate boundary

集約：

- `Workload`
- `Run`
- `Artifact`
- `Schedule`

整合性：

- DB内の集約間は強整合
- runtime状態はpoll/eventによる結果整合

### 3.2 Workload

Container / Wasmを統一した実行単位。

識別：

- `WorkloadID`: UUID
- `name`: 一意必須
- runtime名とは分離

Kind:

```text
WorkloadSpec =
  | container(ContainerSpec)
  | wasm(WasmSpec)
```

共通設定：

- name
- tags
- source
- execution mode
- environment variables
- arguments
- port mappings
- mounts / preopens
- health check
- restart policy
- retention policy
- concurrency policy
- stop policy
- draft / active revision

`ContainerSpec`：

- OCI image reference
- `entrypointOverride`
- container mount

`WasmSpec`：

- Wasm local path / HTTPS URL
- WASI preopen
- WASI socket permission

### 3.3 Desired state

```text
DesiredState =
  | Running
  | Stopped
```

- 常時起動のみ`Running`を使用する。
- `Updating` / `Failed`はdesired stateに含めない。
- 1回実行は`DesiredState=Stopped`のままRun要求を発行する。
- 定期実行の有効 / 無効はschedule enabledとして管理する。

### 3.4 Runtime state

`RuntimeState`は永続化する単一状態ではない。

導出元：

- `DesiredState`
- 最新Run
- `HealthStatus`
- runtime inspect結果
- draft / active revision差分

導出表示状態：

- `Loading`
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

### 3.5 Run

1 Run = 1 process。

識別：

- `RunID`: UUID
- runtime名: `wasmbox-<workloadUUID>-<runUUID>`
- `restartChainID`
- `attemptIndex`

Trigger:

```text
RunTrigger =
  | Manual
  | Scheduled
  | Restart
  | RollingUpdate
  | Resume
```

State:

```text
RunState =
  | Pending
  | Starting
  | Running
  | Succeeded
  | Failed
  | Skipped
  | Terminating
  | Terminated
```

終了理由：

- `StoppedByUser`
- `TerminatedByAppQuit`
- abnormal kill

成功判定：

- exit code 0のみ`Succeeded`
- 非0は`Failed`
- health checkはRun成功条件に含めない

Run保存情報：

- workload ID
- trigger
- state
- scheduled time
- started time
- finished time
- exit code
- termination reason
- resolved artifact ID/hash
- resolved source
- restart chain ID
- attempt index

`Skipped` Run：

- scheduled time
- trigger type
- reason
- resolved source
- log fileなし

### 3.6 Run chain

- restartごと新Runを作成する。
- 同一restart chainは`restartChainID`で連結する。
- `attemptIndex`をRunへ保存する。
- `stableFor`を超えてhealthy継続した場合、restart counterをresetする。
- chain履歴はreset後も残す。

### 3.7 Artifact

sourceとresolved artifactを分離する。

Container source：

- OCI image reference
- `repo:tag`
- digest reference

Wasm source：

- local path
- HTTPS URL

非対応：

- Container build
- OCI archive import
- source自動判定
-任意URL

Resolved artifact：

- Container: digest
- Wasm: SHA-256
- Runはresolved artifact ID/hashを保存する

### 3.8 Schedule

- 5フィールドcronのみ
- 秒フィールドなし
- `@daily` / `@hourly`等の拡張構文なし
- macOS現在のlocal timezoneを都度参照
- DST消失時刻はskip
- DST重複時刻は1回のみ実行
- 定期実行失敗時はretryしない
- 次回cron時刻まで待機する

## 4. Execution modes

### 4.1 Once

- 手動でRun要求を発行する。
- `DesiredState`は`Stopped`のまま。
- 完了後は`Succeeded` / `Failed` / `Terminated`。

### 4.2 Scheduled

- cron時刻にRun要求を発行する。
- 前回Run実行中でも`maxConcurrentRuns`に従う。
- 上限到達時は`Skipped` Runとして記録する。
- 失敗時retryなし。

### 4.3 Always-on

- `DesiredState=Running`。
- process終了時に自動再起動する。
- health check失敗時も自動再起動する。
- GUI再起動後に自動再開する。
- GUI終了時は停止する。
- Mac再起動後は自動起動しない。

## 5. Artifact resolution

### 5.1 Update policy

```text
ArtifactUpdatePolicy =
  | Pinned
  | RefreshOnStart
```

Pinned：

- 初回解決したdigest/hashへ固定する。
- cache消失時は`Failed` Runとする。
- 自動再取得しない。

RefreshOnStart：

- 起動前にsourceを再解決・再取得する。
- 取得失敗時は実行しない。
- 同一内容ならcache再利用する。
- 同一内容ならrevision変化を起こさない。

### 5.2 Container image

- 表示用tagと実行digestを分離する。
- Pinnedは初回digestへ固定する。
- RefreshOnStartはtagを再解決しdigestを更新する。

### 5.3 Wasm

- Pinnedは初回download SHA-256へ固定する。
- 任意expected SHA-256を設定可能。
- 期待hash不一致は`Failed` Run。
- 再取得内容の真実は内容hash。
- ETag / Last-Modifiedは補助情報。

### 5.4 Pin update

- 「再取得してPin更新」はdraftへ新hashを設定する。
- Applyまでactive revisionへ反映しない。
- 実行中Workloadはrolling update選択可能。

### 5.5 Cache

保存先：

```text
~/Library/Application Support/wasmbox/artifacts
```

- hash名で保存する。
- 参照なしartifactはGCする。
- cacheは再起動後も利用可能。

### 5.6 Download

Network:

- macOS system proxyに従う
- workload個別proxyなし

TLS:

- TLS検証は基本有効
- Workloadごとに`allowInsecureTLS`設定可能
- `allowInsecureTLS=true`時はUI警告のみ

Redirect:

- HTTPS→HTTPSのみ許可
- HTTPS→HTTPは拒否
- 最大5回
- 最終URLとresolved hashを記録

Timeout:

- connect timeout: 10秒
- read timeout: 30秒
- total timeout: 10分

## 6. Configuration model

### 6.1 Draft / active revision

- 設定変更は`draftRevision`として保存する。
- 即時適用しない。
- Apply操作で`activeRevision`へ反映する。
- ApplyはWorkload単位。
- draft / active差分を表示する。
- draft破棄可能。
- revision履歴からの復元は非対応。

### 6.2 Apply behavior

- Stopped Workloadは次回起動・次回cronでactive revisionを使用する。
- Always-on WorkloadはApply時にrestart方法を選択できる。
  - rolling update
  - normal restart
- Apply後も実行中revisionと差分がある場合、`UpdateRequiresRestart`を表示する。

### 6.3 Validation

即時検証：

- フィールド単位
- 入力中に表示

保存時検証：

- draft全体
- cron式
- port重複
- path不存在
- hash形式
- concurrencyとport整合性
- kind別必須項目

設定不備：

- `InvalidConfig`
- Runは作成しない

定期実行時点で設定不備：

- `Skipped` Runを記録する

## 7. Environment and arguments

### 7.1 Environment variables

```text
EnvironmentVariableValue =
  | plain(String)
  | secret(KeychainReference)
```

- plain値は設定へ保存する。
- secret値はmacOS Keychainへ保存する。
- host環境変数は継承しない。
- 必要な値はWorkloadへ明示設定する。
- secret値はUI・logでmaskする。

### 7.2 Arguments

- 実行引数は文字列配列。
- shell解釈しない。
- Wasmは`argv`として渡す。

Container：

- `arguments`はimage `CMD` override
- `entrypointOverride`は別フィールド
- `entrypointOverride`未指定時はimage既定

## 8. Storage and mounts

### 8.1 Container mount

- host path -> container path
- `readOnly | readWrite`
- named volume非対応

### 8.2 Wasm preopen

- Workloadごとにpreopen directoryを明示
- `readOnly | readWrite`
- 既定はhost FS許可なし

### 8.3 Path validation

- host path不存在は起動失敗
- 自動作成しない
- UIに「作成して保存」操作を追加可能

## 9. Networking

### 9.1 Port mapping

```text
PortMapping:
  guestPort: number
  hostPort: number | automatic
```

- Container / Wasm両対応
- `hostPort`未指定時は空きport自動割当
- rolling update時は新側hostPortを一時割当
- healthy後に設定hostPortへ切替

### 9.2 Port ownership

- 固定hostPortは全Workloadで一意
- Stopped Workload同士でも重複保存不可
- port mappingなしguestPort重複は許可
- 実listen時にのみ衝突判定する

### 9.3 Wasm socket

- Wasm guest自身がlistenする
- guestがlisten可能なのはWorkload設定のport mappingだけ
- 設定外port要求は起動失敗

### 9.4 Concurrency constraint

- 固定hostPortあり、かつ`maxConcurrentRuns > 1`は`InvalidConfig`
- hostPort未指定なら自動割当で並列実行可能

## 10. Health check

### 10.1 Check type

Container：

- command
- HTTP
- TCP

Wasm：

- HTTP
- TCP

非対応：

- Wasm内部export呼出し

### 10.2 Health status

```text
HealthStatus =
  | Unknown
  | Healthy
  | Unhealthy
  | NotConfigured
```

初期値：

- `Unknown`

初回成功：

- `Healthy`

未設定：

- `NotConfigured`

### 10.3 Threshold

- 連続失敗回数を設定可能
- 既定3回
- 連続成功回数を設定可能
- 既定1回

### 10.4 Timing

- `startPeriod`を設定可能
- 既定10秒
- `unhealthyGracePeriod`を設定可能
- 既定0秒
- 連続失敗後、grace period経過で再起動対象

### 10.5 Restart relationship

- health check起因restartも`maxRestartAttempts`に含める
- health checkはRun成功条件に含めない

## 11. Restart and update

### 11.1 Restart policy

Always-on：

- process終了で自動再起動
- health check失敗で自動再起動
- `maxRestartAttempts`設定可能
- 超過後`Failed`
- `stableFor`超過でcounter reset
- `stableFor`既定5分

### 11.2 Rolling update

手順：

1. 新processを起動
2. health check成功を待つ
3. 旧processを停止
4. 設定hostPortへ切替

Port:

- 新側は一時hostPort
- 切替時に設定hostPortへ移す
- port設定なし・未対応runtimeはnormal restart

失敗時：

- 旧process維持
- 新process停止
- `UpdateFailed`表示
- 更新は保留

### 11.3 Stop policy

既定：

- SIGTERM
- 10秒待機
- SIGKILL

Workloadごとに設定可能：

- stop signal
- stop timeout

Runtime mapping：

- Containerはruntime適切な停止APIへ写像
- WasmはWasmtime process/instance停止処理へ写像

## 12. Scheduler

### 12.1 Runtime availability

- schedulerはGUI起動中のみ動作
- GUI未起動中のmissed runは追走しない
- missed runは`SchedulerMissedWindow`へ集約記録

記録内容：

- workload ID
- missed期間
- 予定回数

### 12.2 Concurrency

- Workloadごとに`maxConcurrentRuns`
- 既定1
- 上限到達時triggerは`Skipped`
- queueしない
- trigger種別による優先順位なし

### 12.3 Unavailable workload

定期実行時点で以下の場合、`Skipped` Run：

- `InvalidConfig`
- `RuntimeUnavailable`

## 13. Logs

### 13.1 Storage

- Runごとにファイル保存
- stdout / stderr分離
- GUIで結合表示可能
- log保持は件数・日数で管理
- 既定Run 100件・log 7日

### 13.2 Secret masking

- 既知secret値は完全一致でmaskして保存
- secret scanningは非対応

### 13.3 Viewer

- 末尾1000行を初期表示
- scrollで遡及読込
- searchはファイル全体
- stdout / stderr切替
- 結合表示可能
- follow中は末尾滞在時のみ追従
- 上scrollでpause
- 新規行badge表示
- 末尾へ戻るbutton

## 14. Metrics

対象：

- CPU
- memory

非対象：

- network
- disk

収集：

- 5秒間隔
- 1分集計
- 24時間保持
- SQLiteへ保存

表示：

- 一覧には出さない
- 詳細画面で表示
- Run選択時は選択Runのmetrics表示

## 15. Events

永続化event：

- `RunCreated`
- `Started`
- `Exited`
- `Failed`
- `HealthChanged`
- `RestartScheduled`
- `Skipped`
- `Orphaned`

揮発event：

- UI通知
- log stream
- metrics更新

UI：

- domain event streamをsubscribe
- DB永続化とUI更新を分離
- event駆動＋runtime status 5秒poll

## 16. Runtime synchronization

### 16.1 Poll

- runtime statusを5秒poll
- runtime状態を真実として扱う
- DB/UIへ反映する
- eventを発行する

### 16.2 External change

- 外部停止は`Exited` / `Orphaned`として反映
- restart policyへ渡す

### 16.3 App restart recovery

起動時：

1. UI即表示
2. `Loading`状態表示
3. DB migration
4. runtime検査
5. orphan確認
6. schedule再開

- runtime unavailableでも設定閲覧・編集可能
- migration前backup完了までは閲覧・編集不可
- migration失敗時は旧version read-only起動を提示

### 16.4 Orphan

- 管理外processは`Orphaned`表示
- Adopt / Stopをユーザー選択
- 管理下証跡があるもののみ自動再関連付け
- runtime側IDで判定

## 17. App lifecycle

### 17.1 GUI restart

- `DesiredState=Running`を永続化
- GUI再起動後に自動再開
- `Resume` triggerでRun作成

### 17.2 Mac restart

- Mac再起動後は自動起動しない
- LaunchAgent登録しない

### 17.3 GUI quit

- 全Workload停止
- 全体timeout 30秒
- 残りはSIGKILL
- 停止失敗のみ`Unknown`
- 次回起動時にorphan確認

Run扱い：

- GUI終了中に自然完了したRunは通常結果保存
- timeout超過でkillされたRunは`TerminatedByAppQuit`

## 18. Persistence

### 18.1 SQLite

保存対象：

- Workload設定
- draft / active revision
- Schedule
- Run metadata
- Run状態遷移event
- metrics
- scheduler missed window

### 18.2 Keychain

保存対象：

- secret environment variable本体

保存しない：

- Run履歴
- log
- metrics
- export JSON

### 18.3 Migration

- migration前にSQLite backup
- migration失敗時はread-only起動
- UIに警告表示
- backup完了まで閲覧・編集不可

## 19. Import / export

### 19.1 Export

対象：

- Workload設定

対象外：

- secret値
- Run履歴
- log
- metrics

secret：

- Keychain参照名のみ保存

### 19.2 Import

- Workload単位
- 全Workload一括

name衝突：

- overwrite
- rename
- skip

既定：

- skip

secret：

- import先で再入力

## 20. Tags and bulk operations

- Workloadはtagを持つ
- group階層なし

一括操作：

- Start
- Stop
- Restart
- Apply draft
- Delete

保護：

- 一括Apply draftは影響一覧表示
- 一括削除は影響一覧表示
- 対象をcheck選択

## 21. Deletion

削除対象：

- Workload設定
- Run metadata
- log
- secret参照

実行中削除：

- 停止→削除を一括実行
- SIGTERM→timeout→SIGKILL完了後に削除
- 強制停止失敗時は削除しない

undo：

- なし

## 22. Use cases

Usecase層を設ける。

代表usecase：

- `CreateWorkload`
- `SaveDraft`
- `ApplyDraft`
- `StartWorkload`
- `StopWorkload`
- `RunOnceNow`

Transaction:

- usecaseごとに1 DB transaction
- runtime呼出はtransaction外
- DB更新→event発行→runtime反映

Runtime failure:

- artifact解決失敗は`Failed` Run
- runtime起動失敗は`Failed` Run
- `InvalidConfig` / `RuntimeUnavailable`はRunなし
- 定期実行時の`InvalidConfig` / `RuntimeUnavailable`は`Skipped` Run

Run開始順序：

1. artifact解決
2. Run作成
3. runtime start

## 23. Runtime adapter

Interface:

```text
RuntimeAdapter =
  start
  stop
  inspect
  logs
  metrics
  update
```

Error:

```text
RuntimeError =
  | Unavailable
  | Invalid
  | NotFound
  | Conflict
  | Timeout
  | Unknown(cause)
```

- runtime固有詳細は`cause`へ保持
- UI / restart policyは分類済みerrorで判断する

## 24. UI requirements

### 24.1 List

表示列：

- name
- kind
- desired state
- runtime state
- health
- next run
- ports

### 24.2 Detail

Tabs:

- Summary
- Runs
- Logs
- Metrics
- Events
- Settings

Summary:

- draft / active差分
- Apply
- discard draft
- update required
- rolling update選択

Runs:

- Run一覧
- 既定最新Run
- 選択Runのlog / event / metrics表示

Logs:

- stdout / stderr切替
- merged view
- search
- follow / pause
- secret mask

Events:

- Run状態遷移
- health変化
- restart
- skipped
- orphan

Settings:

- 即時validation
- 保存時全体validation
- secret入力
- port mapping
- mounts / preopens
- schedule
- restart policy
- retention
- export

## 25. Invariants

1. Workload nameは一意。
2. runtime名は`wasmbox-<workloadUUID>-<runUUID>`。
3. 1 Run = 1 process。
4. `Succeeded`はexit code 0のみ。
5. `Pinned` artifactはresolved digest/hashを変更しない。
6. `RefreshOnStart`の取得失敗時は実行しない。
7. 固定hostPortは全Workloadで一意。
8. 固定hostPortかつ`maxConcurrentRuns > 1`は保存不可。
9. secret値は平文で設定・export・logへ保存しない。
10. host環境変数は継承しない。
11. draftはApplyまでactiveへ反映しない。
12. runtime呼出はDB transactionへ含めない。
13. DB内整合は強整合、runtime状態は結果整合。
14. GUI終了時は管理下Workloadを停止する。
15. orphan processを自動停止しない。
16. Workload削除時は関連log・secret参照を削除する。
17. Runは実行時のresolved artifact ID/hashを保持する。
18. `InvalidConfig` / `RuntimeUnavailable`でruntime起動しない。
19. 定期実行missを追走しない。
20. health check失敗はRun成功判定へ混ぜない。
