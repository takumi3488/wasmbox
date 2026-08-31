# ADR 0014: Runtime capability gaps

- Status: Accepted
- Date: 2026-08-31

## Context

仕様はWasm guest listen、rolling updateのhost port切替、Container stdout/stderr分離を要求する。現行のApple `container` CLIとWasmtime C API（module + WASI Preview 1）には対応APIがない。

## Decision

- Wasm port mappingは起動時に`RuntimeError.invalid`として失敗させ、`Failed` Runとして記録する。socket許可設定は保存可能なままとし、runtime側が対応した時点で有効化する。
- Wasm metricsは`nil`を返し、UIは「Metrics unavailable for Wasmtime」と明示する。
- `RuntimeAdapter.supportsPortHandoff`は本番adapterで`false`とし、rolling update要求はnormal restartへ委譲する。
- Container logsは`container logs`の単一streamをstdoutとして保存し、merged viewで表示する。stderr分離はruntimeが分離出力を提供した時点で実装する。

## Consequences

- 未対応機能はUI/Run履歴で明示され、黙って別挙動にならない。
- runtime側APIが追加された場合、adapter差分のみで対応できる。

## Alternatives

- 独自port proxy: networking stackの実装・権限管理が必要でv1範囲を超える。
- Wasmtime component / WASI Preview 2への切替: 現行module実行・`_start`前提とWASI Preview 1 preopen設定を全面再実装する必要がある。
