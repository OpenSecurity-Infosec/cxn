# PRDs

All active work ships behind **`PRD-008`** and the fork discipline established in **`PRD-001`**.

| PRD | Title | Status | Notes |
|---|---|---|---|
| [PRD-001](PRD-001-fork-plumbing.md) | Fork plumbing and upstream discipline | **Active (Landed)** | `8e6563ff`: sync + patch-surface workflows, PR template, script |
| **[PRD-008](PRD-008-constellation-t3-harness.md)** | **Constellation-exclusive agent harness for T3 Code** | **Active Flagship** | **Canonical direction: raw Constellation harness under T3 Code, `apps01` MVP, profiles, bidirectional signaling** |
| [PRD-002](PRD-002-router-provider.md) | Constellation Router provider (legacy multi-provider framing) | Superseded by `PRD-008` | Pure-logic core in `src/constellation/provider.zig` carries forward into `PRD-008` |
| [PRD-003](PRD-003-semantic-commands.md) | Semantic command system | Deferred / Archived | Earlier console thesis; T3 Code owns UI |
| [PRD-004](PRD-004-editor-vim.md) | Editor core + Vim v1 + keymap | Deferred / Archived | Earlier console thesis; T3 Code owns composer |
| [PRD-005](PRD-005-transcript-history.md) | Transcript navigation + editable forkable history | Deferred / Archived | Earlier console thesis; T3 Code owns transcript & forking |
| [PRD-006](PRD-006-surfaces-kitty-mouse.md) | Mouse + surfaces + Kitty v1 + rich outputs + toggle | Deferred / Archived | Earlier console thesis; T3 Code owns visual rendering |
| [PRD-007](PRD-007-browser-herdr-parity.md) | Herdr qualification + browser v1/v2 + parity gate | Deferred / Archived | Earlier console thesis; T3 Code owns preview & orchestration |

## Active MVP Set

`PRD-001` (landed) + `PRD-008` Phase 1: Constellation-exclusive provider/transport + ACP piloting + operational CLI (`cxn acp`, `status`, `doctor`, `models`, `ask`) + `apps01` (`linux/x64`) deployment replacing fragmented per-provider harnesses in T3 Code.

## Current Implementation State

- Pure-logic provider helpers exist in `src/constellation/provider.zig` (`Profile`, `RoutingMetadata`, `buildCatalog`). Live HTTP transport, dynamic catalog discovery, Constellation `ProviderId` wiring, auto-mode permission reviewer, and `apps01` packaging are next under `PRD-008` Phase 1.
- Legacy local-only prototype files (`commands.zig`, `editor.zig`, `transcript.zig`, `surfaces.zig`, `integration.zig`, `tui.zig`, `console_runtime.zig`) remain on disk from earlier commits and `feat/local-console`; they are frozen and must not receive new feature work.

## PRD Conventions

Each PRD has: Goal, Background, Scope in/out, Requirements, Architecture (upstream touches labeled `upstreamable` or `downstream-hook`, downstream location under `src/constellation/`), Acceptance criteria (built-binary proof), Test plan (focused tests, E2E owner + PGSO classification), Docs, Rollout, and Open questions.
