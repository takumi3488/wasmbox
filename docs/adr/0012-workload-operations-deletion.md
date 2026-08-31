# ADR 0012: Workload operations and deletion

- Status: Accepted
- Date: 2026-08-29

## Context

tagによる一括操作・draft適用・削除は複数Workloadへ影響する。誤操作とorphan processを防ぐ必要がある。

## Decision

- Workloadはtagを持つ。group階層は持たない。
- tag一括操作はStart/Stop/Restart/Apply draft/削除まで可能。
- 一括Apply draft・削除は影響一覧を表示し、対象をチェック選択する。
- Workload削除は設定・Run metadata・log・secret参照を完全削除する。
- 実行中Workload削除は停止→削除を一括実行する。
- 停止はSIGTERM→timeout→SIGKILLまで完了後に削除する。
- 強制停止失敗時は削除しない。
- 削除undoはなし。
- import時のname衝突は上書き/rename/skipを選択。既定skip。

## Consequences

- 一括操作前に影響範囲を確認できる。
- orphan processをDBから消して追跡不能にしない。
- 完全削除によりsecret/logが残らない。

## Alternatives

- Trash: 完全削除と矛盾し、secret/logが残る。
- 履歴残存: 削除したWorkloadのsecret参照・logを残す。
- 即時削除: runtime processがorphan化する。
