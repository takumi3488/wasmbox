# ADR 0008: Persistence and secrets

- Status: Accepted
- Date: 2026-08-29

## Context

設定・Run metadata・metrics・secretを異なる保全レベルで保存する必要がある。

## Decision

- 設定・Run metadata・metricsはSQLiteへ保存する。
- secret値はmacOS Keychainへ保存する。
- log本文はRunごとのファイルへ保存する。
- stdout/stderrは分離する。
- 既知secret値は完全一致でmaskしてlog保存する。
- Run履歴・log保存はWorkloadごとに件数・日数設定する。
- 既定はRun 100件・log 7日。
- migration前にSQLite backupを作成する。
- migration失敗時は既存versionでread-only起動し、UIに警告する。
- export/importは単一・一括両対応。
- secret値はexportせずKeychain参照名のみ保存する。
- Run履歴・logはexport対象外。

## Consequences

- Run履歴検索とWorkload別保持管理を実装できる。
- secretを設定ファイル・log・exportへ漏らしにくい。
- migration失敗時に既存設定を失わない。

## Alternatives

- JSONのみ: 時系列・履歴検索・保持管理に向かない。
- secret平文保存: 漏洩リスクが高い。
- event sourcing全量: v1の実装負荷が高い。
