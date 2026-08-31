# ADR 0010: Domain boundaries and use cases

- Status: Accepted
- Date: 2026-08-29

## Context

UI・scheduler・health monitor・runtime adapterが同じ状態を扱う。集約境界とtransaction境界を固定する必要がある。

## Decision

- 集約は`Workload` / `Run` / `Artifact` / `Schedule`に分離する。
- `WorkloadSpec` enumで`.container(ContainerSpec)` / `.wasm(WasmSpec)`を表現する。
- 共通設定とkind別設定を分離する。
- usecase層を設ける。
  - `CreateWorkload`
  - `SaveDraft`
  - `ApplyDraft`
  - `StartWorkload`
  - `StopWorkload`
  - `RunOnceNow`
- usecaseごとに1 DB transaction。
- runtime呼出はtransaction外。
- DB更新→event発行→runtime反映。
- runtime起動失敗は`Failed` Runとして記録する。
- DB内の集約間整合は強整合。
- runtime状態はpoll/eventで結果整合。
- Run状態遷移eventのみ永続化する。

## Consequences

- Run履歴増加・artifact共有・schedule再評価でWorkload集約が肥大化しない。
- runtime反映失敗時も履歴が残る。
- UIはdomain event streamをsubscribeし、永続化と表示更新を分離できる。

## Alternatives

- Workload集約に全内包: 履歴・schedule・artifact管理が肥大化する。
- CRUDのみ: validation・transaction・event発行が分散する。
- runtime呼出をDB transactionへ含める: runtime停止時にDBを長時間ロックする。
