# Roadmap

Canonical specification: [PRDs/PRD-008-constellation-t3-harness.md](PRDs/PRD-008-constellation-t3-harness.md).

Build order prioritizes keeping a Constellation-exclusive harness live under T3 Code, maintaining clean upstream `vercel-labs/fx` rebases, and advancing harness-to-router signaling on top of the production path.

## Milestone Status

### Phase 0: Fork Foundation (Landed)
1. Fork plumbing, branch topology (`upstream-main` mirror, `main` downstream trunk), sync workflow, and patch-surface KPI (`PRD-001`, landed in `8e6563ff`).
2. Strategic pivot documentation and `AGENTS.md` alignment (`PRD-008`).

### Phase 1: Primary MVP, Raw `cxn` Harness Live on `apps01` Under T3 Code (Landed)
3. **Constellation-exclusive provider and transport:** Registered `.constellation` in `ProviderId` and `provider_set.Set`, HTTP/SSE client against Constellation Router (`/api/v1/models`, `/api/v1/responses`), Bearer API key and `~/.fx/constellation.json` auth, outbound correlation headers, and inbound `X-Constellation-Route-*` metadata capture.
4. **Constellation auto-mode permission reviewer:** Constellation-backed `permission_reviewer` operating in `auto` mode without Vercel AI Gateway.
5. **ACP piloting and Constellation-first defaults:** `cxn acp` with dynamic router catalog discovery, background disk-cached `/models` refresh, `_meta.constellation` routing telemetry, served-model context window accounting, and cross-model `provider_state_json` replay hygiene.
6. **Operational CLI and deterministic E2E proof:** `cxn status --json`, `cxn doctor --json`, `cxn models --json`, `cxn ask`, and `tests/e2e/constellation-harness.test.ts` (classified `verification-only` in `scripts/pgso/corpus.json`).
7. **`apps01` (`linux/x64`) packaging, deployment, and T3 Code unification:** Cross-compiled static `linux/x64` `cxn` binary deployed on `apps01` and wired under T3 Code across Constellation-routed model families.

### Phase 2: Harness Profiles and Bidirectional Signaling (`signaling-v1`) (Landed)
8. **Harness profiles:** Named profile configuration (`balanced`, `economy`, `deep`, `pinned`, plus custom overrides), CLI and env selection (`--profile`, `CXN_PROFILE`), and ACP `session/set_config_option` (`configId: "profile"`).
9. **Joint harness-to-router signaling contract:** Capability-gated `signaling-v1` headers and additive JSON envelope emitted by `cxn` (`X-Constellation-Capabilities: signaling-v1`) and consumed/stripped by `constellation-router`.
10. **Inbound router feedback loop:** Served-model context window and seat-pressure telemetry surfaced into session accounting and ACP `_meta.constellation` updates.

### Milestone `cxn v0.2.0`: Upstream `fx v0.0.18` Sync and Constellation Terminal Shell (Landed)
11. **Upstream `fx v0.0.18` sync (`bb1ec8b50`) and Zig `0.17.1` migration:** Merged upstream `vercel-labs/fx` `v0.0.18` into `main` while preserving Constellation provider, ACP, and profile hooks within the patch-surface budget.
12. **Constellation Catppuccin Mocha / Latte theme engine:** Default `constellation-mocha` dark theme and `constellation-latte` light variant alongside `fx-dark` and `fx-light`, configurable via `CXN_THEME`, `FX_THEME`, and live `/theme` switching.
13. **Dual-version shell, interactive `/profile`, and Grok Build-inspired UX:** Dual `cxn v0.2.0` / `fx v0.0.18` startup header, `--version` (`cxn 0.2.0 (fx 0.0.18)`), `--help`, and `/version`; interactive `/profile` command; enriched `/status` and `cxn status --json` (`cxn_version`, `fx_version`, `profile`, `router`, `theme`); and direct-terminal ergonomics (`Shift+Tab` mode cycling, `Ctrl+T` effort cycling, `Ctrl+X` agent switcher, `-c`/`--continue`, semantic permission badge, live `auto → <model>` indicator, default context + workspace/git-branch statusline).

### Phase 3: Adaptive Workflow Intelligence and Fleet Rollout (Planned / In Progress)
14. **Expanded deterministic workflow analyzers (planned / in progress):** Enrich turn-phase, task-class, and reasoning-effort advisories from test-runner outcomes, diff scale, and compaction pressure with zero extra LLM calls.
15. **Optional profile-gated pre-analysis (planned):** Allow profiles to opt into lightweight pre-classification (`llm_classify`) when deterministic heuristics are ambiguous, benchmarked against deterministic baselines.
16. **Cross-environment rollout and console prototype cleanup (in progress):** Standardize `cxn v0.2.0` + profiles across `apps01`, macOS workstations, and linked T3 Code hosts, and prune frozen `feat/local-console` prototype files (`tui.zig`, `editor.zig`, `surfaces.zig`, `transcript.zig`).

## Deferred / Archived Work

Earlier standalone graphical-console items (`PRD-003` semantic command palette, `PRD-004` Vim modal editor, `PRD-005` editable/forkable TUI transcript, `PRD-006` mouse/surfaces/Kitty graphics, and `PRD-007` Herdr qualification and embedded browser) remain **deferred/archived**. T3 Code owns multi-thread visual orchestration, while `cxn v0.2.0` configures upstream `fx`'s built-in terminal shell for direct CLI sessions.

## Gates

- Focused Zig unit tests, `zig fmt --check src/`, `zig build -Doptimize=ReleaseSafe`, and built-binary verification (`./zig-out/bin/cxn`) per change.
- Deterministic stub-router E2E coverage in `tests/e2e/constellation-harness.test.ts` registered in `scripts/pgso/corpus.json`.
- `./scripts/patch-surface.sh` within budget (warn at 12, fail at 50 upstream-owned files).
- Full CI on the exact commit across all four native runners before marking any pull request ready.
- Binary-size (~7.8 MiB ceiling) and cold-start (`FX_BENCH=1`, 2ms Linux CI) budgets remain observed.
