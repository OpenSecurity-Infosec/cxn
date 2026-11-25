# cxn fork discipline and harness overview

`cxn` (`v0.2.0`) is a downstream distribution of [vercel-labs/fx](https://github.com/vercel-labs/fx), synced to upstream `fx v0.0.18` (`bb1ec8b50`) on Zig `0.17.1`.

Upstream owns the generic agent kernel (loop, tools, permissions, sessions, ACP server, and terminal renderer). `cxn` owns the Constellation-exclusive layer: Constellation Router transport, dynamic catalog discovery, T3 Code ACP integration, harness profiles, bidirectional `signaling-v1` envelopes, and the Constellation terminal shell.

See [../PRDs/PRD-008-constellation-t3-harness.md](../PRDs/PRD-008-constellation-t3-harness.md) for the canonical product specification.

## Release baseline and Constellation terminal shell

- **Dual-version baseline:** `cxn v0.2.0` tracks upstream `fx v0.0.18` (`bb1ec8b50`) and requires Zig `0.17.1`. `cxn --version` prints `cxn 0.2.0 (fx 0.0.18)`, `cxn --help` and `/version` surface both versions, and the interactive startup header displays `cxn v0.2.0` alongside `fx v0.0.18`.
- **Catppuccin Mocha and Latte themes:** `cxn` defaults to `constellation-mocha` (Catppuccin Mocha truecolor palette with Constellation Blue `#89b4fa` and Lavender `#b4befe` accents) and provides `constellation-latte` for light terminals alongside upstream `fx-dark` and `fx-light`. Configure themes via `CXN_THEME`, `FX_THEME`, or `~/.fx/settings.json`, or switch live during a session with `/theme <name>`.
- **Interactive profiles and enriched status:** `/profile` inspects or switches harness profiles (`balanced`, `economy`, `deep`, `pinned`) in-session, matching `--profile <name>` and `CXN_PROFILE`. Both `/status` and `cxn status [--json]` report `cxn_version`, `fx_version`, active `profile`, `router` endpoint, `model`, `auth` source, and active `theme`.
- **Grok Build-inspired terminal UX:** Direct `cxn` sessions configure upstream `fx`'s terminal shell with `Shift+Tab` mode cycling, `Ctrl+T` reasoning-effort cycling, `Ctrl+X` agent switching, `-c` / `--continue` session continuation, a semantic permission badge, a live routed-model indicator (`auto → <model>`), and a default statusline showing context usage plus workspace and git branch identity. T3 Code remains the multi-thread orchestration layer, and these shell defaults do not revive the archived `PRD-003` through `PRD-007` custom console work.

## Branch topology

```text
vercel-labs/fx (upstream, v0.0.18 / bb1ec8b50)
      │
      ▼
origin/upstream-main   ← exact upstream mirror. No direct commits, ever.
      │
      │ merge (PR, human-gated)
      ▼
origin/main            ← shipping downstream `cxn` trunk
      │
      ├── feat/...     (short-lived feature branches)
      └── ...
```

- `upstream-main` mirrors upstream `vercel-labs/fx` `main` exactly. The `Upstream sync` workflow (`.github/workflows/upstream-sync.yml`) fast-forwards it and opens or updates an `upstream-main -> main` pull request without pushing merges directly to `main`.
- `main` is the active downstream `cxn` trunk. Merge `upstream-main -> main`; never rebase `main`.
- Rebase short-lived feature branches onto `main` as needed.
- Every upstream-owned file touched by downstream must be labeled `upstreamable` or `downstream-hook`.

## Patch surface

> downstream patch surface = number of upstream-owned files modified relative to the merge-base with `upstream-main`.

- Warn budget: 12 files. Fail budget: 50 files.
- Enforced by `.github/workflows/patch-surface.yml` via `./scripts/patch-surface.sh`.
- Downstream-owned paths excluded from the count: `src/constellation/`, `docs/`, the two `cxn` workflows, and `scripts/patch-surface.sh`.
- Keep downstream logic inside `src/constellation/` behind thin registration hooks rather than expanding upstream file touches.

## Downstream layout

Downstream implementation lives under `src/constellation/` (`runtime.zig`, `transport.zig`, `catalog.zig`, `profiles.zig`, `signaling.zig`, `permission_reviewer.zig`, `bundle.zig`, and theme/shell helpers), wired into upstream `src/core/`, `src/acp/`, `src/ui/`, and `src/main.zig` through minimal hooks.

## Shipped capabilities vs. Phase 3 roadmap

### Shipped (`cxn v0.2.0` on `fx v0.0.18`)

1. Fork plumbing, `upstream-main` sync automation, and patch-surface guardrails (`PRD-001`), rebased onto `fx v0.0.18` (`bb1ec8b50`, Zig `0.17.1`).
2. Constellation-exclusive provider and transport: default public endpoint `https://infer.cxn.sh/api/v1`, dynamic `GET /models` discovery with disk-cached background sync, `/responses` SSE streaming, correlation headers, `X-Constellation-Route-*` telemetry capture, `~/.fx/constellation.json` and `CXN_API_KEY` resolution, and Constellation-backed `auto` permission review (`PRD-008` Phase 1).
3. Constellation-first ACP server and CLI (`cxn acp`, `cxn status`, `cxn doctor`, `cxn models`, `cxn ask`), cross-model state hygiene, `_meta.constellation` route and signal updates, and `apps01` (`linux/x64`) T3 Code integration (`PRD-008` Phase 1).
4. Harness profiles (`balanced`, `economy`, `deep`, `pinned`) and capability-gated `signaling-v1` bidirectional harness-to-router signaling (`PRD-008` Phase 2).
5. Constellation terminal shell (`cxn v0.2.0`): `constellation-mocha` default and `constellation-latte` light themes, dual-version startup banner and `--version` / `/version`, interactive `/profile` and `/theme`, enriched `/status`, and Grok Build-inspired keybindings and statusline defaults.

### Planned / in-progress (`PRD-008` Phase 3)

1. Expanded deterministic workflow-signal analyzers using test-runner outcomes, diff scale, and compaction state without extra LLM round-trips.
2. Optional profile-gated pre-classification (`llm_classify`) benchmarked against deterministic routing baselines.
3. Multi-environment standardization across linked T3 Code hosts and cleanup of frozen `feat/local-console` prototype files (`tui.zig`, `editor.zig`, `surfaces.zig`, `transcript.zig`).

## Verification

```bash
zig fmt --check src/
zig build -Doptimize=ReleaseSafe
./zig-out/bin/cxn --version
./zig-out/bin/fx --version
./scripts/patch-surface.sh
```
