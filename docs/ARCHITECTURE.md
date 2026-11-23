# Architecture

Canonical specification: [PRDs/PRD-008-constellation-t3-harness.md](PRDs/PRD-008-constellation-t3-harness.md).

## Upstream/downstream rule

Every change touching upstream-owned code is classified as either:

- **Upstreamable**: could go to `vercel-labs/fx` as-is (bug fix, generic improvement, protocol compatibility).
- **Downstream hook**: thin registration point that lets `src/constellation/` plug in (provider registration, ACP option/metadata hook, Constellation CLI default/subcommand dispatch).

If a change is neither, it lives in the wrong place.

`fx` already cleanly separates `src/core/` (agent loop, config, permissions, sessions, tooling, MCP, skills), `src/acp/` (JSON-RPC 2.0 ACP server), `src/gateway/` (HTTP/SSE and Responses protocol), and `src/builtins/` (composition bindings). `cxn` plugs into those seams rather than rewriting them.

## System topology

```text
T3 Code (local macOS or apps01 linux/x64)
  │  ACP JSON-RPC 2.0 over stdio (`cxn acp`)
  ▼
cxn binary (forked from vercel-labs/fx)
  │  Upstream core: agent loop, tools, permissions, sessions, MCP, skills
  │  Downstream layer (`src/constellation/`):
  │    - Constellation Router provider (HTTP/SSE, dynamic `/models`, Bearer auth)
  │    - Constellation auto-mode permission reviewer
  │    - Correlation headers & inbound `X-Constellation-Route-*` telemetry capture
  │    - Harness profiles & outbound workflow signaling envelope (Phase 2)
  │
  │  OpenAI-compatible HTTP/SSE (`/api/v1/models`, `/api/v1/responses` or `/chat/completions`)
  ▼
Constellation Router (`cxn-router` via public `https://infer.cxn.sh/api/v1` by default)
  │  Virtual routing workflows (`constellation/auto|smart|efficient`), seat walk,
  │  quotas, upstream provider runtimes
  ▼
Upstream providers (OpenAI/Codex, Anthropic, xAI, Muse Code, Custom/Go, Cursor)
```

## Downstream layout (`src/constellation/`)

Target module layout for the Constellation harness direction:

```text
src/constellation/
  root.zig          Downstream module root and test aggregator
  provider/         Constellation Router transport, catalog discovery, auth,
                    correlation headers, RoutingMetadata parser, permission reviewer
  signaling/        (Phase 2) Deterministic workflow analyzer, outbound signaling
                    envelope serializer, inbound router feedback consumer
  profiles/         (Phase 2) Profile config schema, loader, CLI/ACP option wiring
  acp_bridge/       Helpers for Constellation ACP configOptions & `_meta.constellation`
  cli/              `cxn status`, `cxn doctor`, `cxn models` snapshot/formatting helpers
```

Note on legacy files: flat prototype files from the earlier graphical-console direction (`editor.zig`, `commands.zig`, `transcript.zig`, `surfaces.zig`, `integration.zig`, `tui.zig`, `console_runtime.zig`) currently remain on disk from earlier commits. They are frozen and must not be extended for new work.

## Key integration seams

### 1. Provider & Transport Seam
- Upstream `ProviderId` (`src/core/config/model_provider.zig`) and `provider_set.Set` (`src/core/gateway/provider_set.zig`) gain a `.constellation` entry wired to `src/constellation/provider/`.
- Reuses upstream `src/gateway/responses_protocol.zig` for Responses API serialization and SSE reduction, keeping transport diff small and inheriting upstream tool-call/image/cancellation hardening automatically.
- Includes a Constellation-backed `permission_reviewer` so `auto` permission mode never falls back to Vercel Gateway.

### 2. ACP Piloting Seam (`src/acp/`)
- `cxn acp` speaks standard ACP JSON-RPC 2.0 over stdio to T3 Code.
- Startup in Constellation mode initializes directly against Constellation Router (no Vercel/Codex/Grok credential requirement).
- `configOptions` advertises the live Constellation Router model catalog (including `constellation/auto` and concrete router models), effort levels, session modes, and (in Phase 2) active harness profile.
- Response headers (`X-Constellation-Route-Model`, `X-Constellation-Route-Path`, `X-Constellation-Route-Label`, `X-Constellation-Route-Effort`, `X-Constellation-Route-Classify`) are parsed into `RoutingMetadata` and forwarded in ACP `session/update` `_meta.constellation` notifications.

### 3. Bidirectional Signaling Seam (Phase 2 — Target Design)
- **Outbound (Harness -> Router):** Controlled by the active profile. Emits lightweight headers (`X-Constellation-Profile`, `X-Constellation-Signal-Version`) and an additive JSON signaling block describing live harness state (turn/step phase, task class, complexity/reasoning advisory, context fill ratio). `cxn-router` consumes these as advisory inputs to routing workflows and strips the block before forwarding to upstream providers.
- **Inbound (Router -> Harness):** Harness consumes served-model identity and routing metadata to keep context-window limits, compaction thresholds, and ACP telemetry accurate even when `constellation/auto` switches concrete models mid-session.
- **Trust boundary:** Harness signals are advisory evidence only. Constellation Router retains final routing, seat-selection, ACL, and quota authority.

### 4. Cross-Model Session Continuity
- Because `constellation/auto` or T3 Code model changes can switch model families mid-session, opaque provider-specific reasoning state (`provider_state_json`) must be gated by served model family so tool continuations remain valid across providers.
