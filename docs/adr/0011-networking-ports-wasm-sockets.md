# ADR 0011: Networking, ports, and Wasm sockets

- Status: Accepted
- Date: 2026-08-29

## Context

ContainerとWasmの両方でHTTP/TCP health checkとrolling updateを実現する必要がある。Wasmはguestが実際にlistenする必要がある。

## Decision

- Container/Wasm両方でport mappingとHTTP/TCP health checkを対応する。
- WasmはWasmtime socket許可を使い、guest自身がlistenする。
- guestがlisten可能なのはWorkload設定のport mappingだけ。
- 設定外port要求は起動失敗。
- `guestPort -> hostPort`を明示する。
- `hostPort`未指定なら空きport自動割当。
- 同一hostPortはStopped同士でも設定保存不可。
- port mappingなしguestPort重複は許可。
- 固定hostPortかつ`maxConcurrentRuns > 1`は`InvalidConfig`。
- 保存時は全Workload設定衝突、起動時は実listen port衝突を検査する。
- artifact取得はmacOS system proxyに従う。
- TLS検証は基本有効。Workloadごとに`allowInsecureTLS`を設定可能。
- Wasm URL redirectはHTTPS→HTTPSのみ、最大5回。
- download timeoutはconnect/read/total個別設定。既定10秒/30秒/10分。

## Consequences

- WasmのHTTP/TCP health checkをhost側から自然に実行できる。
- port衝突を保存時・起動時の両方で説明できる。
- rolling update時だけ一時host port割当を許可する。
- TLS downgradeを防ぐ。

## Alternatives

- WasmKit独自proxy: networking stack実装が必要。
- 任意port許可: 他Workload・他processとの衝突を管理できない。
- global insecure TLS: 1つの検証用Workloadが全体のTLS検証を弱める。
