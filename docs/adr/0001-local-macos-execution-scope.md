# ADR 0001: Local macOS execution scope

- Status: Accepted
- Date: 2026-08-29

## Context

ContainerとWasmをGUI管理する。v1の実行場所を決める必要がある。

## Decision

v1の`ExecutionHost`は`LocalMac`のみ。

## Consequences

- SSH・Kubernetes・クラウドの状態同期を持たない。
- `DesiredState=Running`とruntime状態の乖離はlocal runtimeへの問合せで解決する。
- GUI起動中のみschedulerを実行する。

## Alternatives

- Remote host support: 状態同期・認証・障害処理が必要。
- Kubernetes support: desired state管理が二重化する。
