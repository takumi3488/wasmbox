# ADR 0005: Scheduling and concurrency

- Status: Accepted
- Date: 2026-08-29

## Context

定期実行と常時起動を同じRun管理に載せる。同時実行・cron評価・missed runの扱いを決める必要がある。

## Decision

- 定期実行は5フィールドcronのみ。
- macOS現在のローカルタイムゾーンを都度参照する。
- DST消失時刻はskip、重複時刻は1回のみ実行する。
- 定期実行失敗時はリトライしない。
- GUI起動中のみschedulerを実行する。
- GUI未起動のmissed runは`SchedulerMissedWindow`へ集約記録する。
- Workloadごとに`maxConcurrentRuns`を設定可能にする。
- 上限到達時のtriggerは`Skipped` Runとして記録する。
- 既定`maxConcurrentRuns = 1`。
- trigger種別で優先順位を変えない。

## Consequences

- queue蓄積による遅延実行を避けられる。
- 長期停止後に大量Runを生成しない。
- scheduler失敗と実行失敗を履歴上分離できる。

## Alternatives

- queue: 遅延した実行が蓄積する。
- missed run追走: GUI未起動中の環境で期待しない大量実行が起きる。
- cron秒精度: v1のUIとschedulerを複雑にする。
