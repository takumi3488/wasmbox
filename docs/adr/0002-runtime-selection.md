# ADR 0002: Runtime selection

- Status: Accepted
- Date: 2026-08-29

## Context

ContainerとWasmの両方を同じGUIで管理する。runtimeごとの差異をdomain modelへ漏らさない必要がある。

## Decision

- Container runtime: Apple `container`
- Wasm runtime: Wasmtime C APIをSwift組込み
- runtime差は`RuntimeAdapter`へ閉じ込める
- Docker/Podman/WasmKit adapterはv1対象外

## Consequences

- Apple `container`はApple silicon + macOS 26以降が前提。
- Wasmtime組込みによりWASI socketを利用したHTTP/TCP health checkを実現する。
- runtime未導入・最小version未満は`RuntimeUnavailable`として扱う。
- runtime検査は存在・version・service起動・権限・接続を確認する。

## Alternatives

- WasmKit: WASI socket APIが未実装でHTTP/TCP health check要件を満たせない。
- External `wasmtime` CLI: process管理は容易だが、app lifecycleと強く結びつく組込み制御を弱める。
