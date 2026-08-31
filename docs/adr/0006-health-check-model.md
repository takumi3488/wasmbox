# ADR 0006: Health check model

- Status: Accepted
- Date: 2026-08-29

## Context

ContainerとWasmで利用可能なhealth check手段が異なる。Run成功判定と可用性判定を混ぜない必要がある。

## Decision

- Container health check: command / HTTP / TCP
- Wasm health check: host側HTTP / TCP
- Wasm内部export呼出しはv1対象外
- 初期`HealthStatus = Unknown`
- health check未設定は`NotConfigured`
- 連続失敗回数を設定可能、既定3回
- 連続成功回数を設定可能、既定1回
- `startPeriod`と`unhealthyGracePeriod`を両方設定可能
- `startPeriod`既定10秒、`unhealthyGracePeriod`既定0秒
- health checkはRunの成功条件に含めない

## Consequences

- 一時的な通信失敗で即再起動しない。
- 起動直後と運用中の不安定さを別に扱える。
- Run結果はexit codeに限定できる。

## Alternatives

- 生存確認のみ: HTTP/TCP serviceの実可用性を判定できない。
- health成功をRun成功条件にする: 常時起動processが終了しない限り成功にならない。
