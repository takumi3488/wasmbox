# ADR 0004: Artifact source and update policy

- Status: Accepted
- Date: 2026-08-29

## Context

Container image tagとWasm URLは同じsource表記でも内容が変わり得る。再現性と更新性を分けて管理する必要がある。

## Decision

- source種別を限定する。
  - Container: OCI image reference（`repo:tag` / digest）
  - Wasm: local path / HTTPS URL
- `ArtifactUpdatePolicy`を設定可能にする。
  - `Pinned`: resolved digest/hash固定
  - `RefreshOnStart`: 起動前に再解決・再取得
- `RefreshOnStart`の取得失敗時は実行しない。
- 内容の真実はdigest/SHA-256。ETag・Last-Modifiedは補助。
- Containerは表示tagと実行digestを分離。
- Wasm Pinnedは初回SHA-256固定。任意expected SHA-256も設定可能。
- 期待hash不一致は`Failed` Runとして記録する。
- artifact cacheは`~/Library/Application Support/wasmbox/artifacts`。
- hash名で保存し、参照なしartifactはGCする。

## Consequences

- Pinned実行は再現可能。
- RefreshOnStartは最新artifact取得を実行条件にできる。
- Pinned cache消失は自動再取得せず、`Failed` Runとして可視化する。

## Alternatives

- 毎回最新取得: 再現性がない。
- cache fallback: 古いartifactを黙って実行する。
- 自動source判定: Container/Wasmの誤判定を招く。
