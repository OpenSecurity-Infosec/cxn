# PRD-008 — Constellation-Exclusive Agent Harness for T3 Code

**Status:** Active Flagship (Supersedes `PRD-002` multi-provider framing; defers `PRD-003` through `PRD-007` console UI work).
**Active baseline:** `cxn v0.2.0` on upstream `vercel-labs/fx` `v0.0.18` (`bb1ec8b50`, Zig `0.17.1`).
**Depends on:** `PRD-001` (Fork plumbing and upstream discipline, landed in `8e6563ff`).
**Target delivery branch:** `main` (active downstream `cxn` trunk; `upstream-main` mirrors `vercel-labs/fx` `main`).

---

## 1. Executive Summary & Strategic Pivot

`cxn` is a lean, raw, native Zig agent harness forked from `vercel-labs/fx` whose sole primary objective is to live underneath **T3 Code** and connect exclusively to **Constellation Router** (`cxn-router`).

This PRD establishes a deliberate strategic pivot:

- **Previous direction (archived/deferred):** Turning `fx` into a rich standalone terminal console (`Ghostty -> Herdr -> FX`) with a custom Vim modal editor, editable/forkable TUI transcript blocks, mouse hit maps, Kitty graphics placements, and an embedded browser helper (`PRD-003` through `PRD-007`, prototyped on `feat/local-console`).
- **New core focus (active):** **T3 Code** is the human orchestration layer (threads, workspace/worktree management, approvals, UI, remote environments like `apps01`). **Constellation Router** is the inference control plane and upstream provider runtime hub. **`cxn`** is the dedicated, raw agent harness connecting the two: T3 Code pilots `cxn` over ACP (JSON-RPC 2.0), `cxn` executes local coding tools/sessions/permissions, and `cxn` routes all model inference exclusively through Constellation Router.

Owning both the harness (`cxn`) and the model router (`constellation-router`) creates a long-term architectural advantage that third-party harnesses cannot match: **bidirectional harness-to-router signaling** and **configurable harness profiles**. Instead of forcing the router to guess task difficulty blindly from raw prompt text alone, `cxn` can emit structured workflow and reasoning signals alongside requests, and react to router telemetry returned on responses ("eating on both ends").

### Primary MVP Objective

Deploy a working, raw `cxn` CLI/ACP harness onto **`apps01`** (`linux/x64`) and unify T3 Code operations there: replace the fragmented collection of per-provider harnesses (`codex`, `claudeAgent`, `opencode-cxn`, `muse`, etc.) with a single personalized **`cxn` harness** where all model execution and provider-specific runtimes are abstracted upstream into the public Constellation Router inference endpoint (`https://infer.cxn.sh/api/v1`). `cxn` always assumes external/public client usage and never assumes co-location with `cxn-router` on loopback or a private network.

---

## 2. Ecosystem Architecture: The Three-Tier Harness Model

Within the development ecosystem, T3 Code operates as a super-harness over agent backends while Constellation Router fills the unified inference-hub niche. Three integration tiers exist:

| Tier | Pattern | Role in Ecosystem | Limitations / Why Tier 3 Wins |
|---|---|---|---|
| **Tier 1 (Interim bridge)** | Generic third-party harness pointed at Constellation (e.g., `opencode-cxn` on `apps01` exposing `cxn-router/*` models) | Useful working bridge today | Inherits third-party harness prompts, runtime weight, and closed wire framing; cannot emit Constellation-native workflow signaling. |
| **Tier 2 (Optional future option)** | Individual vendor harnesses (`codex`, `claudeAgent`, `grok`, `muse`) each re-pointed upstream to Constellation Router | Optional fallback when vendor-native harness behavior is specifically desired | Duplicates agent runtimes even though Constellation Router already implements upstream provider runtimes internally; fragments host configuration, auth, and updates on `apps01`; blocks single-thread cross-provider routing. |
| **Tier 3 (Core focus of `cxn`)** | **Dedicated Constellation-exclusive raw harness** (`cxn`, forked from `vercel-labs/fx`) piloted by T3 Code over ACP and talking exclusively to Constellation Router | **Primary unified runtime** on `apps01` and local machines | Single ~7.8 MiB native Zig binary, sub-2ms cold start, full ACP/tool/permission/session engine inherited from upstream `fx`, native Constellation catalog + virtual routing, and an owned bidirectional signaling channel with `cxn-router`. |

### Layer Boundaries

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ T3 Code (Orchestration Layer)                                           │
│ Threads, worktrees, approvals, visual UI, multi-agent coordination,     │
│ linked environments (local macOS <-> apps01 linux/x64)                  │
└───────────────────────────────────┬─────────────────────────────────────┘
                                    │ ACP JSON-RPC 2.0 over stdio
                                    │ (`cxn acp` / `fx acp`)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ cxn Harness (This Repository — Raw Zig Agent Runtime, v0.2.0)           │
│ Agent loop, tools (fs/shell/search/MCP/skills/subagents), permissions,  │
│ durable sessions, Constellation Router transport & dynamic catalog,     │
│ harness profiles, signaling-v1, Catppuccin Mocha terminal shell         │
└───────────────────────────────────┬─────────────────────────────────────┘
                                    │ OpenAI-compatible HTTP/SSE
                                    │ (`/api/v1/models`, `/api/v1/responses`
                                    │  or `/api/v1/chat/completions`)
                                    │ + Constellation correlation headers
                                    │ + Additive signaling-v1 envelope
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Constellation Router (`cxn-router` — Control Plane & Runtime Hub)       │
│ Public inference endpoint: `https://infer.cxn.sh/api/v1` (always        │
│ default; overridable via `CXN_ROUTER_URL` for local test stubs only)    │
│ Backed by `https://router.cxn.sh` SoT (seats, OAuth/keys, catalog,      │
│ quota/reserves, routing workflows: `constellation/auto|smart|efficient`)│
└───────────────────────────────────┬─────────────────────────────────────┘
                                    │ Provider-native upstream runtimes
                                    ▼
  OpenAI/Codex · Anthropic/Claude · xAI/Grok · Muse Code · Custom/Go · Cursor
```

### Strict Ownership Split

1. **T3 Code owns orchestration and UX:** thread lifecycle, UI presentation, human approval prompts, git worktree management, scheduled tasks, and environment linking. `cxn` does not compete with T3 Code's UI.
2. **`cxn` owns single-session execution and harness-side signaling:** tool execution, sandboxing, permission evaluation, durable session state, context compaction, MCP/skills loading, Constellation Router transport, harness profiles, and extracting/emitting workflow hints from live agent state.
3. **Constellation Router owns inference routing and provider runtimes:** model catalog, virtual routing workflows (`constellation/auto`, `constellation/smart`, `constellation/efficient`), seat selection, quota reserve enforcement, upstream credential custody/refresh, and wire adaptation for each underlying model vendor. `cxn` never embeds static model catalogs, vendor OAuth flows, or quota/seat selection logic.
4. **Upstream `vercel-labs/fx` owns the generic agent kernel:** `cxn` stays a disciplined upstream fork (`upstream-main` mirrors `vercel-labs/fx` `main`, `main` ships downstream `cxn` product changes, downstream code lives under `src/constellation/` behind thin `downstream-hook` seams).

---

## 3. Grounded Current State (Shipped vs. Missing)

To prevent drift or false assumptions, this table documents what is verified to exist today versus what remains to be built.

| Capability | Current Status | Ground Truth |
|---|---|---|
| Fork plumbing & CI guardrails (`PRD-001`) | **Shipped** | `upstream-main` mirrors `vercel-labs/fx` (`v0.0.18` / `bb1ec8b50`); `main` is the active downstream trunk; `scripts/patch-surface.sh`, `.github/workflows/upstream-sync.yml`, and `.github/workflows/patch-surface.yml` exist. |
| Core Zig agent loop, tools, permissions, sessions, MCP, skills | **Shipped (upstream `fx v0.0.18`)** | Synced to upstream `fx v0.0.18` (`bb1ec8b50`, Zig `0.17.1`) in `src/core/`, `src/tools/`, `src/builtins/`. |
| ACP JSON-RPC 2.0 server (`fx acp` / `cxn acp`) | **Shipped (upstream `fx v0.0.18`)** | Present in `src/acp/` (`initialize`, `session/new`, `load`, `resume`, `list`, `close`, `prompt`, `cancel`, `set_config_option`, `set_mode`). |
| T3 Code `fx` driver | **Shipped (in T3 Code)** | T3 Code on both local macOS and `apps01` (`linux/x64`) drives `cxn` over ACP. |
| Constellation Router server (`cxn-router`) | **Shipped (separate repo)** | Running on `apps01` (`https://infer.cxn.sh`) and loopback (`127.0.0.1:6630`). Serves `/api/v1/models`, `/api/v1/responses`, `/api/v1/chat/completions`, Bearer auth, correlation headers, and `X-Constellation-Route-*` response headers. |
| Constellation provider pure-logic stubs | **Shipped (superseded by `src/constellation/` runtime)** | Original `src/constellation/provider.zig` remains frozen; live Constellation runtime lives in `runtime.zig`, `transport.zig`, `catalog.zig`, `permission_reviewer.zig`, `bundle.zig`. |
| Constellation-exclusive provider wiring (`cxn` mode, stream, catalog, auto permission reviewer) | **Shipped (Phase 1 MVP)** | `cxn` activates Constellation-exclusive defaults (`https://infer.cxn.sh/api/v1`, `constellation/auto`, dynamic `/models`, Responses API streaming, Constellation-routed `auto` permission reviewer, `FX_AUTH_MODE=host-managed`, `~/.fx/constellation.json`). |
| Constellation-first CLI/ACP defaults & T3 Code `provider-fx` compatibility | **Shipped (Phase 1 + Phase 2)** | `cxn acp` advertises `agentInfo.name: "cxn"`, Constellation-only `provider`, dynamic `model` list with background disk-cached refresh, `effort`, `profile`, `_meta.constellation` route/signal telemetry, `gateway:<model>` slug normalization, and legacy `FX_PROVIDER=codex|grok` probe isolation. |
| `linux/x64` build & installation onto `apps01` + T3 Code activation | **Shipped (Phase 1 + Phase 2 rollout)** | Cross-compiled static `linux/x64` binary deployed on `apps01` and wired to T3 Code against `https://infer.cxn.sh/api/v1`. |
| Harness profiles (`--profile`, `CXN_PROFILE`, `/profile`, ACP `profile` config option) | **Shipped (Phase 2 + `cxn v0.2.0`)** | Built-in `balanced`, `economy`, `deep`, and `pinned` profiles in `src/constellation/profiles.zig` with CLI/env/TUI/ACP switching and custom JSON override support. |
| Bidirectional harness-to-router signaling (`signaling-v1`) | **Shipped (Phase 2)** | Deterministic workflow analyzer in `src/constellation/signaling.zig` + capability-gated `signal_version: 1` JSON envelope (`X-Constellation-Capabilities: signaling-v1`), matched with `constellation-router` `harness_signal` workflow node and upstream stripping (`feat/harness-signaling-v1`). |
| `cxn v0.2.0` Constellation terminal shell | **Shipped (`cxn v0.2.0`)** | Catppuccin Mocha (`constellation-mocha` default) and Latte (`constellation-latte` light) themes (`CXN_THEME` / `FX_THEME` / `/theme`), dual-version startup header and `--version` / `/version` (`cxn 0.2.0 (fx 0.0.18)`), interactive `/profile`, enriched `/status` & `cxn status --json` (`cxn_version`, `fx_version`, `profile`, `router`, `theme`), and Grok Build-inspired UX (`Shift+Tab`, `Ctrl+T`, `Ctrl+X`, `-c`/`--continue`, semantic permission badge, `auto → <model>`, context + workspace/git-branch statusline). |
| Expanded Phase 3 deterministic analyzers & multi-machine rollout | **Planned / In Progress (Phase 3)** | Deeper test-runner, diff-scale, and compaction feedback loops, optional profile-gated pre-classification, and fleet-wide T3 Code rollout. |
| Local console TUI prototype (`feat/local-console`, `src/constellation/tui.zig`, `editor.zig`, `surfaces.zig`, `transcript.zig`) | **Deferred / Frozen** | Legacy prototype from the earlier graphical-console direction (`PRD-003`..`PRD-007`). Must not receive new feature investment; `cxn v0.2.0` configures upstream `fx`'s built-in terminal shell instead. |

---

## 4. Phased Roadmap & Requirements

### Phase 1 — Primary MVP: Raw `cxn` Harness on `apps01` Under T3 Code

**Goal:** Get a minimal, rock-solid `cxn` binary installed on `apps01`, piloted by T3 Code over ACP, and routing 100% of inference through Constellation Router with zero dependency on Vercel AI Gateway, direct ChatGPT OAuth, or direct xAI OAuth.

#### 4.1.1 Constellation-Exclusive Provider & Transport

1. **Constellation provider registration:** Register `.constellation` as a first-class provider behind a thin `downstream-hook` in `model_provider.zig`, `provider_set.zig`, `provider_catalog.zig`, and `builtins/providers.zig`, with implementation living under `src/constellation/provider/`.
2. **Constellation-default runtime mode (`cxn` invocation):** When invoked as `cxn` (`argv[0]` basename is `cxn`, or configured with `provider = "constellation"` / `CXN_ROUTER_URL`), automatically activate Constellation-exclusive defaults: `provider = constellation`, default endpoint `https://infer.cxn.sh/api/v1`, and zero requirement for Vercel AI Gateway, ChatGPT Codex OAuth, or SuperGrok OAuth credentials during `initialize`, `session/new`, `session/load`, or `ask`. Bare `fx` invocation retains upstream compatibility for upstream E2E suites.
3. **Configuration & endpoint resolution (Public Infer Always):**
   - Canonical default base URL is always public infer: **`https://infer.cxn.sh/api/v1`**. Assume `cxn` will be used from arbitrary machines and external environments, never exclusively inside the `apps01` host or private LAN.
   - Explicit override via `CXN_ROUTER_URL` (alias `CONSTELLATION_ROUTER_URL`) or profile settings (`~/.fx/settings.json` / `~/.cxn/settings.json`) is supported for local test stubs or custom deployments, with no implicit fallback to loopback.
   - Auth via Constellation client API key (`CXN_API_KEY` / `CONSTELLATION_API_KEY` or configured secret store) sent as `Authorization: Bearer <key>`. Keep `FX_AUTH_MODE=host-managed` working when an outer boundary injects auth. Never log secrets or keys.
4. **Inference wire protocol:**
   - Primary inference transport targets Constellation Router's OpenAI-compatible Responses endpoint (`POST <base_url>/responses`), reusing upstream `src/gateway/responses_protocol.zig` for streaming SSE, function tool calls, tool results, reasoning summaries, and cancellation.
   - Include a Chat Completions fallback/mode (`POST <base_url>/chat/completions`) if needed for router routes or deployments where Chat Completions is required, selectable by router capability metadata or config without duplicating core agent logic.
   - Respect upstream `fx` cancellation (`cancel_flag`), deadlines, and delivery certainty (`DeliveryCertainty`) semantics so agent retries stay safe.
5. **Dynamic Constellation model catalog:**
   - Fetch `GET <base_url>/models` dynamically using the configured Constellation credential.
   - Ship **zero hardcoded static model lists** in `cxn`. Advertise whatever executable concrete models and virtual routing models (`constellation/auto`, `constellation/smart`, `constellation/efficient`) the router returns, preserving router ordering/metadata (context window, tool support, vision capability, virtual `kind: "auto"` flag) where provided.
   - Default model when unpinned: `constellation/auto` (or first router-advertised default if `constellation/auto` is not advertised).
   - Fail cleanly and explicitly if the router is unreachable or returns 401/403/503; never silently fall back to Vercel Gateway.
6. **Constellation correlation headers (MVP wire hygiene):**
   - Emit outbound headers on every router request:
     - `x-constellation-client: cxn`
     - `x-constellation-client-version: <version>`
     - `x-constellation-conversation-id: <session_id>` (enables `cxn-router` conversation-to-seat affinity already shipped in `internal/execute/public_session.go`)
   - Capture inbound response headers into `RoutingMetadata` on every completed turn:
     - `X-Constellation-Route-Model`
     - `X-Constellation-Route-Path`
     - `X-Constellation-Route-Label`
     - `X-Constellation-Route-Effort`
     - `X-Constellation-Route-Classify`
     - `X-Constellation-Media-Dropped`
     - `X-Constellation-Media-Translated`
7. **Auto-mode permission reviewer over Constellation:**
   - Upstream `fx` runs in `auto` permission mode by default and calls the active provider's `permission_reviewer` for unresolved tool actions.
   - Wire a Constellation-backed `permission_reviewer` in the `.constellation` `provider_set.Bundle` that issues the narrow security review request through Constellation Router (using a fast configured review model or router-designated route, defaulting safely if unavailable without opening a TUI prompt or calling Vercel Gateway).

#### 4.1.2 T3 Code ACP Integration (`cxn acp`)

1. **Full ACP lifecycle parity:** `initialize`, `session/new`, `session/load`, `session/resume`, `session/list`, `session/close`, `session/prompt`, `session/cancel`, `session/set_config_option`, and `session/set_mode` operate cleanly against Constellation Router.
2. **Dynamic model & option advertisement:**
   - `session/new` and `session/load` populate `configOptions` with the live Constellation Router catalog (`id: "model"`), session modes (`id: "mode"`), and reasoning effort (`id: "effort"`).
   - `session/set_config_option` accepts any model present in the active Constellation catalog (including virtual models like `constellation/auto` and concrete models like `claude-opus-5-5`, `gpt-6.1-sol`, `gpt-6-luna`, `muse-ember-1.0`) and switches immediately without re-authenticating or restarting the ACP process.
   - In Constellation-exclusive mode, `provider` does not force or suggest unrelated upstream providers (`vercel`, `codex`, `grok`).
3. **Routing telemetry over ACP:**
   - Emit captured `RoutingMetadata` (actual served model, route path, effective effort, classify status) in structured `session/update` `_meta.constellation` notifications and debug traces so T3 Code and operators can observe which concrete model served each turn under `constellation/auto`.
4. **Accurate context window accounting under virtual routing:**
   - When `constellation/auto` routes a turn to a concrete model returned in `X-Constellation-Route-Model`, resolve context window metadata against the served model (from the router catalog) so `usage_update` and auto-compaction thresholds remain honest.
5. **Cross-model turn hygiene:**
   - When a session switches models mid-conversation (either manually via `set_config_option` or dynamically via `constellation/auto`), strip or gate incompatible vendor-specific opaque `provider_state_json` blobs so turn N+1 on a different upstream model family never fails with HTTP 400.

#### 4.1.3 Minimal Operational CLI & `apps01` Deployment

1. **Binary packaging:**
   - Build a stripped ReleaseSafe `linux/x64` binary cleanly from this repo (`zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-...`, verifying glibc/musl compatibility on `apps01`).
   - Expose the binary on `apps01` as `cxn` (e.g., `/usr/local/bin/cxn` or agreed user bin path, keeping `./zig-out/bin/fx` build conventions intact locally and documenting exact binary identity / SHA-256 on deploy).
2. **Diagnostic CLI & Constellation terminal shell surface:**
   - `cxn --version` (prints dual Constellation and upstream version identity: `cxn 0.2.0 (fx 0.0.18)`).
   - `cxn --help` (exposes `cxn v0.2.0`, `fx v0.0.18`, `--profile`, and Constellation launch options).
   - `cxn status [--json]` / `cxn doctor [--json]`: reports `cxn_version`, `fx_version`, `profile`, `router`, `model`, `auth`, and `theme`, and validates router connectivity against `GET /models` without spending inference tokens.
   - `cxn models [--json]`: lists the live Constellation Router catalog.
   - `cxn ask [--profile <name>] [--model <id>] [--json] "<prompt>"`: non-interactive single-turn smoke and automation path.
   - `cxn acp [--profile <name>] [--model <id>] [--log-file <path>]`: primary T3 Code integration entrypoint.
   - Direct interactive `cxn` TUI (`cxn v0.2.0` shell on `fx v0.0.18`): defaults to `constellation-mocha` (`constellation-latte` light variant), renders the dual-version header, and supports `/version`, `/profile`, `/theme`, enriched `/status`, `Shift+Tab` mode cycling, `Ctrl+T` effort cycling, `Ctrl+X` agent switching, `-c`/`--continue`, semantic permission badge, `auto → <model>` routed-model indicator, and default context + workspace/git-branch statusline.
3. **T3 Code activation on `apps01`:**
   - Enable and configure the `cxn` harness instance inside T3 Code on `apps01` (pointing T3 Code's `fx` ACP driver or a dedicated `cxn` provider instance at the installed `cxn` binary with Constellation env/config).
   - Confirm T3 Code threads on `apps01` can run real engineering tasks using `cxn` across multiple router-backed model families without invoking `codex`, `claudeAgent`, `opencode-cxn`, or `muse` directly.

#### 4.1.4 Phase 1 (MVP) Acceptance Criteria

All five gates must pass before Phase 1 is declared complete:

1. **Local stub & unit proof:** Focused Zig unit tests for Constellation transport, catalog parsing, header emission/parsing, cross-model history hygiene, and permission reviewer pass; `zig fmt --check src/` and `zig build -Doptimize=ReleaseSafe` succeed; deterministic E2E suite (`tests/e2e/constellation-harness.test.ts`, classified `verification-only` in `scripts/pgso/corpus.json`) passes against a local stub router for `ask`, `models`, `status --json`, and full `acp` tool-call + session-resume lifecycles.
2. **Patch-surface & performance hygiene:** `./scripts/patch-surface.sh` reports upstream-owned touches within budget (`<= 12` warn threshold); `FX_BENCH=1` cold start and stripped binary size show no unexplained regression.
3. **Full CI:** Exact-commit Full CI passes across all four native runners (`ubuntu-24.04`, `ubuntu-24.04-arm`, `macos-15-intel`, `macos-15`).
4. **`apps01` binary verification:** Installed `cxn` binary on `apps01` passes `cxn --version`, `cxn status --json`, and `cxn models --json` against the configured Constellation Router endpoint with clean stderr.
5. **End-to-end T3 Code thread proof on `apps01` (operator-approved live run):** A real T3 Code thread on `apps01` piloted through `cxn acp` completes a multi-turn coding workflow involving file reads, tool execution, and session resume across at least two distinct Constellation-routed models (including `constellation/auto`), with routing metadata observable and zero process aborts.

---

### Phase 2 — Harness Profiles & Bidirectional Signaling ("Eating on Both Ends")

**Goal:** Give `cxn` explicit **profiles** and a versioned, additive **Constellation Signaling Envelope** so the harness and router collaborate on model and reasoning-effort selection instead of operating blind to each other.

> **Status note:** Phase 2 profiles (`--profile`, `CXN_PROFILE`, `/profile`, ACP `profile`) and capability-gated `signaling-v1` are **shipped in `cxn v0.2.0`**. Phase 3 expanded deterministic analyzers (test-runner, diff-scale, and compaction feedback loops) and optional pre-classification remain **planned / in progress**.

#### 4.2.1 Harness Profiles

Profiles allow an operator or T3 Code thread to declare *what signaling and routing behavior* the harness should negotiate with Constellation Router.

- **Configuration location:** `~/.fx/constellation-profiles.json` (or profile block inside `~/.fx/settings.json`), overridable via CLI (`--profile <name>`), environment (`CXN_PROFILE`), interactive TUI (`/profile <name>`), and ACP (`session/set_config_option` with `configId: "profile"`).
- **Starter profile set (illustrative target):**
  - `default` / `balanced`: targets `constellation/auto`; emits step-phase and complexity hints; allows router to choose concrete model and effort per turn/step.
  - `economy`: targets `constellation/efficient`; signals aggressive preference for high-efficiency models (e.g., `muse-ember-1.0`, `gpt-6-luna`) on routine tool continuations and mechanical edits.
  - `deep`: targets `constellation/smart` (or high-tier virtual workflow); biases signals toward high reasoning effort for architecture, debugging, and security review.
  - `pinned`: disables adaptive model overrides; passes through an explicit user-chosen model verbatim while still sending session affinity and receiving telemetry.
- **Profile contract properties:**
  - `name`: stable identifier (`[a-z0-9_-]+`).
  - `default_model`: virtual or concrete catalog ID.
  - `signaling`: enable/disable flags per signal category (`workflow_hint`, `step_phase`, `context_telemetry`, `reasoning_advisory`).
  - `effort_policy`: `"auto"` | `"fixed:<tier>"` | `"advisory"`.
  - `allow_mid_turn_route_change`: boolean indicating whether the harness invites step-level rerouting across tool-loop iterations or prefers turn-level model stickiness.

#### 4.2.2 Outbound Signaling Contract (Harness -> Router)

To avoid polluting upstream vendor schemas, signaling is sent in an additive, versioned namespace that `cxn-router` consumes during workflow evaluation and **strips before forwarding** to any upstream model provider:

- **Wire placement (joint decision with `constellation-router`):**
  - HTTP headers for fast pre-body inspection and tracing:
    - `X-Constellation-Client: cxn`
    - `X-Constellation-Profile: <profile_name>`
    - `X-Constellation-Signal-Version: 1`
    - `X-Constellation-Conversation-Id: <session_id>`
  - Request JSON additive object (`constellation` top-level key or `metadata.constellation` — exact placement finalized jointly in a versioned fixture under `constellation-router/contracts/`):

```json
{
  "constellation": {
    "signal_version": 1,
    "harness": "cxn",
    "harness_version": "0.2.0",
    "profile": "balanced",
    "session_id": "sess_01...",
    "turn_index": 3,
    "step_index": 2,
    "phase": "tool_continuation",
    "advisory": {
      "task_class": "mechanical_edit",
      "complexity": "medium",
      "reasoning_need": "medium",
      "latency_sensitivity": "normal",
      "context_fill_ratio": 0.28,
      "tool_calls_in_turn": 4,
      "recent_tool_error": false
    }
  }
}
```

- **Concrete example of mutual efficiency:**
  - A user asks a thread in T3 Code to inspect a build error, update three files, and re-run tests.
  - Step 1 (initial root-cause analysis): `cxn` signals `phase: "initial_plan"`, `complexity: "high"`, `reasoning_need: "high"` → router selects a frontier reasoning model (e.g., `claude-opus-5-5` or `gpt-6.2-sol`).
  - Step 2 (applying straightforward edits after the plan is clear / summarizing test output): `cxn` signals `phase: "tool_continuation"`, `complexity: "medium"`, `reasoning_need: "medium"` → router workflow sees the harness advisory plus seat quotas and routes to `muse-ember-1.0` or `gpt-6-luna` instead of spending frontier quota unnecessarily.
- **Safety & compatibility invariants:**
  1. **Advisory only:** Harness signals inform Constellation Router's operator-published routing workflows (`internal/routing`); they never bypass seat admission, allowed-model ACLs, or quota reserves.
  2. **Fail-open forward/backward compatibility:** An older `cxn-router` that does not understand `signal_version: 1` ignores unknown fields cleanly (or only parses when advertised via router capability discovery). Never break generic OpenAI compatibility.
  3. **Strict stripping before upstream:** `cxn-router` removes the `constellation` envelope before sending payloads to OpenAI/Anthropic/xAI/Muse/Cursor upstream APIs.
  4. **No secret leakage:** Signaling blocks contain structural workflow state only — never raw secrets, tokens, or unredacted environment variables.

#### 4.2.3 Inbound Signaling Contract (Router -> Harness)

Constellation Router returns structured routing feedback to `cxn`:

- **Response headers (available today in `cxn-router`):** `X-Constellation-Route-Model`, `X-Constellation-Route-Path`, `X-Constellation-Route-Label`, `X-Constellation-Route-Effort`, `X-Constellation-Route-Classify`, `X-Constellation-Media-Dropped`, `X-Constellation-Media-Translated`.
- **Future additive response/SSE metadata (Phase 2+ joint contract):**
  - Effective served model capabilities (context window, max output tokens, vision/tool capabilities) so `cxn` adjusts compaction and tool budgets accurately mid-session.
  - Quota/pressure hints (e.g., `seat_pressure: "normal" | "tight"`) so the harness can avoid gratuitous high-token speculative tool bursts when subscription windows are nearly exhausted.
  - Structured routing rationale surfaced cleanly to T3 Code via ACP `session_info_update` `_meta.constellation`.

---

### Phase 3 — Adaptive Workflow Analyzers & Ecosystem Rollout

1. **Deterministic harness-side signal analyzers (first):** Derive `phase`, `task_class`, `complexity`, and `reasoning_need` deterministically from real harness state (turn count, step index, whether prior tool call failed, diff/file size, presence of compilation/test errors, explicit user/T3 options) with zero extra LLM latency.
2. **Optional local/fast-model pre-analysis (later, gated by profile):** Where deterministic signals are ambiguous, allow a profile to opt into lightweight classification or router-side `llm_classify` (`constellation/jev`), measuring real token/latency savings against baseline pinned runs.
3. **Multi-environment parity:** Roll out the same `cxn` binary, profile schema, and T3 Code setup across `apps01`, local macOS dev machines, and any additional linked T3 Code environments, retiring redundant per-provider CLI harnesses as confidence is proven.

---

## 5. Upstream Fork Discipline & Architecture Map

`cxn` remains an upstream fork of `vercel-labs/fx`. Every implementation PR must respect these structural constraints:

### Planned Downstream Layout (`src/constellation/`)

```text
src/constellation/
  root.zig                Downstream module root and test aggregator
  provider/               Constellation Router client, catalog discovery, auth,
                          correlation headers, RoutingMetadata parser, permission reviewer
  signaling/              (Phase 2) Harness workflow analyzer, outbound envelope builder,
                          inbound router feedback adapter
  profiles/               (Phase 2) Profile config schema, loader, CLI/ACP option binding
  acp_bridge/             Thin helpers for Constellation ACP configOptions & _meta updates
  cli/                    `cxn status`, `cxn doctor`, `cxn models` snapshot/formatting helpers
```

*(Legacy flat files from the earlier console prototype — `editor.zig`, `commands.zig`, `transcript.zig`, `surfaces.zig`, `integration.zig`, `tui.zig`, `console_runtime.zig` — remain frozen until explicitly pruned or archived in a cleanup PR.)*

### Upstream Touch Budget (`scripts/patch-surface.sh`)

Every modification to an upstream-owned file must be labeled in the PR description as either:
- `upstreamable` — generic fix or improvement suitable for `vercel-labs/fx`, or
- `downstream-hook` — minimal registration seam delegating implementation to `src/constellation/`.

Expected upstream-owned hook sites for Phase 1 MVP:
1. `src/core/config/model_provider.zig` — add `.constellation` to `ProviderId` (`downstream-hook`).
2. `src/core/gateway/provider_set.zig` — add `.constellation` bundle slot (`downstream-hook`).
3. `src/core/auth/provider_catalog.zig` — add Constellation metadata entry (`downstream-hook`).
4. `src/builtins/providers.zig` — wire `constellation.provider.bundle` (`downstream-hook`).
5. `src/acp/server.zig` & `src/acp/sessions.zig` — thin hooks for Constellation default startup, dynamic catalog refresh, and `_meta.constellation` updates (`downstream-hook`).
6. `src/core/cli/cli_surface.zig` & `src/main.zig` — Constellation-exclusive default provider selection and `cxn` CLI subcommand dispatch (`downstream-hook`).

Total anticipated MVP patch surface: ~8 upstream-owned files (well under the 12-file warn threshold and 50-file fail budget).

---

## 6. Disposition of Prior PRDs (`PRD-001` through `PRD-007`)

| PRD | Title | New Status | Rationale |
|---|---|---|---|
| `PRD-001` | Fork plumbing and upstream discipline | **Active (Landed)** | Branch topology (`main` mirror, `constellation` downstream), upstream sync, and patch-surface KPI remain mandatory. |
| `PRD-002` | Constellation Router provider | **Superseded by `PRD-008`** | Multi-provider console framing replaced by Constellation-exclusive T3 Code harness; pure-logic core in `provider.zig` carries forward. |
| `PRD-003` | Semantic command system | **Deferred / Archived** | T3 Code owns human UX; custom terminal command palettes are out of scope. |
| `PRD-004` | Editor core + Vim v1 + keymap | **Deferred / Archived** | T3 Code owns prompt composition; modal TUI editor is out of scope. |
| `PRD-005` | Transcript navigation + forkable history | **Deferred / Archived** | T3 Code owns transcript browsing, forking, and thread transfer. |
| `PRD-006` | Mouse + surfaces + Kitty v1 + rich outputs | **Deferred / Archived** | T3 Code owns visual rendering (`html_render`, media, diffs). |
| `PRD-007` | Herdr qualification + browser v1/v2 + parity gate | **Deferred / Archived** | T3 Code owns preview/browser panels and multi-session orchestration. |
| **`PRD-008`** | **Constellation-exclusive agent harness for T3 Code** | **Active Flagship** | **Canonical product definition, MVP, and phased roadmap.** |

---

## 7. Non-Goals

- **No graphical terminal console / TUI IDE work:** Do not expand `tui.zig`, `editor.zig`, `surfaces.zig`, Kitty graphics, mouse hit maps, or Herdr nesting.
- **No provider runtime duplication in `cxn`:** Do not add direct Anthropic/Muse/Cursor/OpenAI OAuth flows or per-vendor seat management into `cxn`. Constellation Router owns all upstream runtimes and credentials.
- **No orchestrator bloat:** Do not build multi-thread management, fleet views, or worktree schedulers inside `cxn`. T3 Code owns orchestration.
- **No silent contract drift:** Do not hardcode model names (e.g., `claude-opus-5-5`, `muse-ember-1.0`, `gpt-6-luna`) into `cxn` source code as static routing tables. Models come dynamically from Constellation Router.
- **No binary-size or cold-start regression:** Keep the native binary small (~7.8 MiB target ceiling) and startup latency fast (`FX_BENCH=1` <= 2ms on Linux CI).

---

## 8. Technical Risks & Mitigations

1. **Auto-mode permission reviewer dependency on Vercel Gateway:**
   - *Risk:* Upstream `fx` runs in `auto` permission mode and invokes the active provider's `permission_reviewer`. Without a Constellation reviewer, `auto` mode fails or attempts to hit Vercel.
   - *Mitigation:* Implement a Constellation-backed `permission_reviewer` in Phase 1 using Constellation Router's inference endpoint (configured review model or router default) with strict fail-safe hold semantics on error.
2. **T3 Code `fx` driver dynamic model & option wiring:**
   - *Risk:* T3 Code's built-in `fx` driver currently advertises `models: ["default"]` with `effort` options on `apps01`.
   - *Mitigation:* Verify during Phase 1 how T3 Code consumes ACP `configOptions` from `fx acp` vs static driver model lists; support both `--model` / `CXN_MODEL` / `CXN_PROFILE` process configuration and live ACP `session/set_config_option` so T3 Code can drive either `constellation/auto` or explicit catalog models cleanly.
3. **Wire protocol compatibility across all router-backed providers:**
   - *Risk:* Constellation Router exposes both `/api/v1/responses` and `/api/v1/chat/completions`, and different upstream executors (Codex, xAI, Muse Code, Custom/Go, Cursor) translate through `internal/openaiwire`.
   - *Mitigation:* Standardize on `/api/v1/responses` first (reusing battle-tested `src/gateway/responses_protocol.zig`), verify live against `infer.cxn.sh` across multiple router-backed executors, and keep `/api/v1/chat/completions` as a clean fallback transport if any adapter requires it.
4. **Mid-session model switching under `constellation/auto`:**
   - *Risk:* Reasoning blobs (`provider_state_json`) or context-window assumptions from Model A break Model B on the next step.
   - *Mitigation:* Gate opaque provider state replay by served model family and refresh context-window limits from `X-Constellation-Route-Model` + router catalog metadata.
5. **Cross-compilation & libc compatibility on `apps01`:**
   - *Risk:* Building on macOS arm64 for `apps01` (`linux/x64`) can hit glibc version mismatches if dynamically linked against a newer host libc.
   - *Mitigation:* Cross-compile explicitly with Zig targeting `x86_64-linux-musl` or the exact glibc version on `apps01` (verified before install), and record exact commit SHA + binary SHA-256 on deployment.

---

## 9. Resolved Decisions & Remaining Open Questions

### Resolved Decisions

1. **Public infer always:** `cxn` always defaults to the public Constellation Router inference endpoint (`https://infer.cxn.sh/api/v1`). Do not assume `cxn` runs inside the `apps01` host or private network; `CXN_ROUTER_URL` remains an explicit override for stubs/dev only.
2. **`cxn` invocation identity:** Invoking the binary as `cxn` activates Constellation-exclusive defaults (`provider = constellation`, default URL `https://infer.cxn.sh/api/v1`, no Vercel/Codex/Grok credential requirement), while bare `fx` retains upstream compatibility for upstream E2E suites.
3. **Pre-MVP console commits:** Existing commits from `feat/local-console` stay merged into the unified build (they do not conflict) while remaining frozen/non-core until pruned later.

### Remaining Open Questions

1. **T3 Code driver integration on `apps01`:** Will T3 Code on `apps01` configure an instance of the existing `fx` driver pointed at `/usr/local/bin/cxn` (with `CXN_API_KEY` against public `https://infer.cxn.sh/api/v1`), or will T3 Code also add a dedicated `cxn` driver/instance that reads dynamic Constellation models and profiles from ACP?
2. **Phase 2 signaling JSON placement:** Should the additive `constellation` signaling envelope live as a top-level request field (`{"model": "...", "constellation": {...}}`) or nested inside OpenAI's `metadata` field (`{"metadata": {"constellation": {...}}}`), and should it be formalized as a shared contract fixture under `constellation-router/contracts/`?
