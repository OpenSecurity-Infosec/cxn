# Roadmap

Canonical specification: [PRDs/PRD-008-constellation-t3-harness.md](PRDs/PRD-008-constellation-t3-harness.md).

Build order prioritizes getting a raw, Constellation-exclusive harness live under T3 Code on `apps01` first, then layering profiles and bidirectional harness-to-router signaling on top of a proven production path.

## Active Sequence

### Phase 0 — Fork Foundation (Landed)
1. Fork plumbing, branch topology (`upstream-main` mirror, `main` downstream trunk), sync workflow, and patch-surface KPI (`PRD-001`, landed in `8e6563ff`).
2. Strategic pivot documentation and `AGENTS.md` alignment (`PRD-008`).

### Phase 1 — Primary MVP: Raw `cxn` Harness Live on `apps01` Under T3 Code
3. **Constellation-exclusive provider & transport:** Register `.constellation` in `ProviderId` / `provider_set.Set`, implement HTTP/SSE client against Constellation Router (`/api/v1/models`, `/api/v1/responses` primary with `/api/v1/chat/completions` fallback as needed), Bearer API key auth, outbound correlation headers, and inbound `X-Constellation-Route-*` metadata capture.
4. **Constellation auto-mode permission reviewer:** Wire a Constellation-backed `permission_reviewer` so `auto` mode runs cleanly without Vercel Gateway.
5. **ACP piloting & Constellation-first defaults:** Make `cxn acp` boot cleanly against Constellation Router, advertise the live discovered catalog (including `constellation/auto`), emit `_meta.constellation` routing telemetry, update context windows from the served model, and guard cross-model `provider_state_json` replay.
6. **Operational CLI & deterministic E2E proof:** Ship `cxn status --json`, `cxn doctor --json`, `cxn models --json`, `cxn ask`, and `tests/e2e/constellation-harness.test.ts` (against a local stub router, classified in `scripts/pgso/corpus.json`).
7. **`apps01` (`linux/x64`) packaging, deployment & T3 Code unification:** Cross-compile and install `cxn` on `apps01`, wire T3 Code on `apps01` to pilot `cxn acp`, and validate real multi-turn coding threads across multiple router-backed model families, replacing fragmented per-provider harnesses.

### Phase 2 — Harness Profiles & Bidirectional Signaling ("Eating on Both Ends")
8. **Harness profiles:** Implement named profile configuration (`balanced`, `economy`, `deep`, `pinned`, custom), CLI/env selection (`--profile`, `CXN_PROFILE`), and ACP `session/set_config_option` (`configId: "profile"`).
9. **Joint harness-to-router signaling contract:** Finalize the versioned additive signaling schema with `constellation-router` (headers + stripped JSON envelope) and implement fail-open emission in `cxn` and workflow consumption in `cxn-router`.
10. **Inbound router feedback loop:** Consume served-model capabilities and quota/pressure advisories from router responses into compaction, tool pacing, and ACP observability.

### Phase 3 — Adaptive Workflow Intelligence & Rollout
11. **Deterministic workflow analyzers:** Infer turn phase, task class, and reasoning-effort advisories from real harness state (tool-error recovery, initial planning vs mechanical tool continuation, context pressure) with zero extra model hops.
12. **Cross-environment rollout:** Standardize `cxn` + profiles across `apps01`, local macOS dev machines, and additional linked T3 Code environments; optionally prune frozen legacy console prototype files.

## MVP Acceptance (Proves the Pivot)

```text
FX upstream kernel (ACP + tools + permissions + sessions)
+ Constellation-exclusive provider (dynamic catalog + Responses/Chat SSE + headers + reviewer)
+ Operational CLI (`cxn acp`, `cxn status`, `cxn models`, `cxn ask`)
+ Cross-compiled linux/x64 binary installed on apps01
+ T3 Code piloting `cxn` on apps01 across multiple Constellation-routed models & `constellation/auto`
```

## Deferred / Archived Work

Earlier console-centric items (`PRD-003` semantic commands, `PRD-004` Vim editor, `PRD-005` editable/forkable TUI transcript, `PRD-006` mouse/surfaces/Kitty graphics, `PRD-007` Herdr qualification and embedded browser) are **deferred/archived**. T3 Code owns the human interface.

## Gates

- Focused Zig unit tests + `zig fmt --check src/` + `zig build -Doptimize=ReleaseSafe` + built-binary verification per change.
- Deterministic stub-router E2E test registered in `scripts/pgso/corpus.json`.
- `./scripts/patch-surface.sh` within budget (warn at 12, fail at 50 upstream-owned files).
- Full CI on the exact commit across all four native runners before marking any PR ready.
- Binary-size (~7.8 MiB ceiling) and cold-start (`FX_BENCH=1`, 2ms Linux CI) budgets remain observed.
- Live `apps01` verification against `cxn-router` with operator approval before declaring MVP deployed.
