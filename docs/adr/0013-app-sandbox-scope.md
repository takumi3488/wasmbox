# ADR 0013: App sandbox scope

- Status: Accepted
- Date: 2026-08-31

## Context

v1はlocal Container / Wasm workloadを管理する。仕様は任意host pathのcontainer mountとWASI preopen、Apple `container` CLI実行、任意local Wasm pathの実行を要求する。App Sandbox下ではuser-selected scope外のhost pathとCLI起動が拒否される。

## Decision

- appはApp Sandboxを有効化しない。
- `Config/wasmbox.entitlements`は空とし、追加entitlementを持たない。
- host path許可はWorkload設定（container mount / WASI preopen）に限定し、validationでpath不存在を拒否する。
- secretは引き続きmacOS Keychainへ保存する。

## Consequences

- 仕様どおり任意host pathのmount / preopenとApple `container` CLI実行が可能。
- sandboxによる追加隔離を持たないため、Workload設定が実効的な権限境界になる。
- Mac App Store配布は対象外となる。

## Alternatives

- App Sandbox + user-selected read-write: mount / preopenごとにsecurity-scoped bookmarkが必要で、常時起動Workloadの再開時に権限復元が破綻する。
- helper process分離: v1のlocal実行スコープに対して実装・配布負荷が過大。
