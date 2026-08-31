# ADR 0007: Configuration draft and rolling update

- Status: Accepted
- Date: 2026-08-29

## Context

実行中Workloadの設定変更を即時反映すると、意図しない停止・port変更・secret変更が起きる。

## Decision

- 設定は`draftRevision`として保存する。
- Apply操作で`activeRevision`へ反映する。
- ApplyはWorkload単位。
- draft/active差分を表示し、draft破棄可能。
- revision履歴からの復元はv1対象外。
- 常時起動はRolling Updateを選択可能。
- Rolling Update: 新process起動 → healthy確認 → 旧process停止。
- 新側host portは一時割当し、切替時に設定host portへ移す。
- 新側がhealthyにならない場合、旧processを維持し新processを停止する。
- port設定なし・未対応runtimeは通常再起動。

## Consequences

- 実行中processを誤って停止しない。
- 無停止更新の失敗時も旧processを維持できる。
- port衝突時にrolling updateを強制しない。

## Alternatives

- 即時反映: 編集中の不完全設定が実行へ漏れる。
- revision履歴復元: v1のUI・migration範囲を超える。
- 旧停止後に新起動: 無停止更新にならない。
