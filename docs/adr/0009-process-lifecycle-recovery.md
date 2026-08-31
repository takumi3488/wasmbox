# ADR 0009: Process lifecycle and recovery

- Status: Accepted
- Date: 2026-08-29

## Context

GUI終了・異常終了・外部からのruntime変更が起きても、管理状態とruntime状態を再整合する必要がある。

## Decision

- GUI再起動後は`DesiredState=Running`のWorkloadを自動再開する。
- Mac再起動後は自動起動しない。
- GUI終了時は全Workloadを停止する。
- GUI終了停止は全体timeout 30秒後にSIGKILLする。
- 停止失敗のみ`Unknown`として次回起動時にorphan確認する。
- 起動時は前回`Running` Runをruntimeへ問合せ、存在すれば再関連付けする。
- 管理外processは`Orphaned`表示し、Adopt/Stopをユーザー選択する。
- runtime側IDは`wasmbox-<workloadUUID>-<runUUID>`。
- UI更新はevent駆動＋runtime status 5秒poll。
- pollで検出したruntime状態を真実としてDB/UIへ反映する。

## Consequences

- GUI再起動で管理下serviceを復旧できる。
- GUI外で起動されたprocessを誤って停止しない。
- runtime外部変更をrestart policyへ反映できる。

## Alternatives

- LaunchAgent: daemon管理・権限・配布が必要。
- 管理状態優先: 外部停止を検知できない。
- orphan自動停止: 同名の非管理processを殺す危険がある。
