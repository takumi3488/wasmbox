# ADR 0003: Desired state and restart policy

- Status: Accepted
- Date: 2026-08-29

## Context

常時起動Workloadはprocess終了やhealth check失敗後にどう復旧するかを決める必要がある。

## Decision

- 常時起動は`DesiredState=Running`で表現する。
- process終了・health check失敗は自動再起動する。
- `maxRestartAttempts`を設定可能にし、超過後は`Failed`で停止する。
- health check起因のrestartも`maxRestartAttempts`に含める。
- `stableFor`を設定可能にし、連続healthy期間超過でrestart counterをresetする。
- `stableFor`既定値は5分。

## Consequences

- 設定ミスによる再起動stormを防げる。
- 間欠障害後に安定したWorkloadは再びrestart上限まで許容できる。
- restartは新しいRunとして記録される。

## Alternatives

- 無期限再試行: CPU・logを消費し続ける。
- health専用counter: 設定項目と判定が増える。
