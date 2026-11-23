# cxn fork discipline

`cxn` is a downstream distribution of [vercel-labs/fx](https://github.com/vercel-labs/fx).
Upstream owns the generic agent kernel (loop, tools, permissions, sessions, ACP server). `cxn` owns the Constellation-exclusive harness layer: Constellation Router transport, dynamic catalog integration, T3 Code ACP tailoring, harness profiles, and bidirectional harness-to-router signaling.

See [../PRDs/PRD-008-constellation-t3-harness.md](../PRDs/PRD-008-constellation-t3-harness.md) for the active product specification.

## Branch topology

```text
vercel-labs/fx (upstream)
      │
      ▼
origin/upstream-main   ← exact upstream mirror. No direct commits, ever.
      │
      │ merge (PR, human-gated)
      ▼
origin/main            ← shipping downstream `cxn` trunk
      │
      ├── feat/constellation-provider   (post-MVP feature branching)
      ├── feat/constellation-acp-mvp
      ├── feat/apps01-deploy
      ├── feat/profiles-signaling
      └── ...
```

- `upstream-main` tracks upstream `vercel-labs/fx` `main` exactly. The `Upstream sync` workflow
  (`.github/workflows/upstream-sync.yml`) fast-forwards it and opens/updates
  an `upstream-main -> main` PR. It never pushes downstream merges directly to `main`.
- `main` is the active downstream trunk (unified development until Phase 1 MVP; feature branches return after MVP).
- Merge `upstream-main -> main`. Never rebase the distribution trunk.
- Rebase short-lived `feat/*` branches onto `main` as needed.
- Every upstream-owned file touched by downstream must be either an
  `upstreamable` change or a thin `downstream-hook`. See patch surface below.

## Patch surface

> downstream patch surface = number of upstream-owned files modified
> relative to the merge-base with `upstream-main`.

- Warn budget: 12 files. Fail budget: 50 files.
- Enforced by the `Patch surface` workflow on PRs and pushes to
  `main`, via `scripts/patch-surface.sh`.
- Downstream-owned paths (excluded from the count):
  `src/constellation/`, `docs/` (upstream has no `docs/` dir, so all of it
  is downstream by definition), the two cxn workflows, and the script
  itself. Register new downstream areas in `OWNED_PREFIXES`.
- If the count grows, the fix is architecture (move code downstream behind a
  hook), not budget inflation.

## Downstream layout

New code lives in `src/constellation/` (see `src/constellation/README.md`
for the planned sub-areas). Registration points into upstream code stay
minimal and explicit.

## Active Build Order

1. Fork plumbing and upstream discipline (`PRD-001`, landed).
2. Constellation-exclusive provider & transport (dynamic `/models`, Responses/Chat SSE, correlation headers, `X-Constellation-Route-*` capture, auto-mode permission reviewer).
3. Constellation-first ACP server & operational CLI (`cxn acp`, `cxn status`, `cxn doctor`, `cxn models`, `cxn ask`, cross-model replay hygiene, `_meta.constellation` updates).
4. `apps01` (`linux/x64`) packaging, deployment, and T3 Code unification (Primary MVP).
5. Harness profiles and versioned bidirectional harness-to-router signaling (`PRD-008` Phase 2).
6. Deterministic workflow-signal analyzers and multi-environment rollout (`PRD-008` Phase 3).

*(Earlier TUI/console items — Vim composer, editable transcript, Kitty graphics, Herdr, embedded browser — are archived/deferred.)*

## Verification

```bash
zig fmt --check src/
zig build -Doptimize=ReleaseSafe
./zig-out/bin/fx --version
./scripts/patch-surface.sh
```
