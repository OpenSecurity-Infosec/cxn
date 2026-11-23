# cxn Docs

`cxn` is a lean, Constellation-exclusive agent harness forked from `vercel-labs/fx`, built to run underneath **T3 Code** and connect exclusively to **Constellation Router** (`cxn-router`).

Start here:

- `PRDs/PRD-008-constellation-t3-harness.md` — **Active flagship PRD**: strategic pivot, three-tier ecosystem model, `apps01` MVP, profiles, and bidirectional harness-to-router signaling.
- `VISION.md` — product identity, layer ownership split (T3 Code / `cxn` / Constellation Router / upstream `fx`), and non-goals.
- `ARCHITECTURE.md` — upstream/downstream rule, patch-surface discipline, `src/constellation/` layout, and ACP/router integration seams.
- `ROADMAP.md` — active phased sequence (MVP on `apps01` -> profiles & bidirectional signaling -> adaptive workflow intelligence).
- `REPOSITORY-STRATEGY.md` — `upstream-main` vs `main` branches, merge discipline, upstream sync.
- `PRDs/README.md` — full PRD index including active and archived/deferred console PRDs.

Normative fork discipline (branches, patch surface, sync) lives in `cxn/README.md`.

## Terms

- **T3 Code**: the human orchestration layer and super-harness (threads, worktrees, approvals, visual UI, linked environments such as `apps01`).
- **FX**: upstream native Zig coding agent kernel from `vercel-labs/fx` (agent loop, tools, sessions, permissions, MCP, skills, subagents, ACP server).
- **Constellation Router (`cxn-router`)**: inference router and control plane serving OpenAI-compatible endpoints (`/api/v1/models`, `/api/v1/responses`, `/api/v1/chat/completions`), virtual routing workflows (`constellation/auto|smart|efficient`), seat/quota management, and upstream provider runtimes. Public inference default is `https://infer.cxn.sh/api/v1` (with `https://router.cxn.sh` as control-plane source of truth); `cxn` never assumes private-LAN or loopback co-location.
- **`cxn`**: this downstream harness distribution — upstream `fx` tailored exclusively for T3 Code ACP piloting, Constellation Router inference, profiles, and bidirectional signaling.
- **Patch surface**: number of upstream-owned files modified by `cxn` relative to `upstream-main`. First-class maintainability KPI.
