# src/constellation — downstream Constellation harness layer

All `cxn`-owned code lives here. Upstream `src/` files are touched only for thin registration points (provider registration, ACP option/metadata hooks, Constellation CLI defaults/subcommands). See [docs/PRDs/PRD-008-constellation-t3-harness.md](../../docs/PRDs/PRD-008-constellation-t3-harness.md) for the active specification and [docs/cxn/README.md](../../docs/cxn/README.md) for fork discipline.

## Shipped Modules (`PRD-008` Phase 1 + Phase 2)

```text
src/constellation/
  root.zig                 Downstream module root and test aggregator
  runtime.zig              `cxn` invocation detection, public-infer-always base URL
                           (`https://infer.cxn.sh/api/v1`), API key/model env resolution,
                           T3 Code `gateway:<model>` slug normalization, legacy backend
                           probe isolation, and per-session `RouteTelemetry` store
  transport.zig            Constellation Router OpenAI Responses API (`/responses`)
                           streaming transport matching `validatePublicBody`, outbound
                           signaling headers + capability-gated `signaling-v1` JSON body,
                           and inbound router feedback header capture
  catalog.zig              Dynamic `/models` discovery provider (`model_catalog.Provider`
                           and `CliModelCatalogProvider`) + `X-Constellation-Capabilities`
                           negotiation
  profiles.zig             Built-in harness profiles (`balanced`, `economy`, `deep`,
                           `pinned`), CLI/env/ACP profile state, and custom JSON overrides
  signaling.zig            Deterministic zero-latency workflow analyzer (`phase`,
                           `task_class`, `complexity`, `reasoning_need`, context ratio)
                           and `signal_version: 1` JSON envelope serializer
  permission_reviewer.zig  Constellation-exclusive `auto`-mode security reviewer
  bundle.zig               Exclusive Constellation `provider_set.Set` and `gateway_provider`
```

## Current Stage

- **Phase 1 MVP shipped:** Invoking the built binary as `cxn` (installed at `zig-out/bin/cxn`) activates Constellation-exclusive defaults (`https://infer.cxn.sh/api/v1`, `constellation/auto`, `CXN_API_KEY` or `FX_AUTH_MODE=host-managed`), dynamic `/models` discovery, Responses API tool-loop execution, Constellation-routed `auto` permission review, and ACP `agentInfo` / `configOptions` / `_meta.constellation` route telemetry.
- **Phase 2 shipped:** Built-in harness profiles (`--profile balanced|economy|deep|pinned`, `CXN_PROFILE`, ACP `profile` + `effort` config options), deterministic zero-latency workflow signaling (`initial_plan` / `tool_continuation` / `recovery` / `final_synthesis`), fail-open capability-gated `signaling-v1` JSON body envelope (`X-Constellation-Capabilities: signaling-v1` or `CXN_SIGNALING=body|headers|off`), and bidirectional router telemetry (`seatPressure`, `contextWindow`, `signalAccepted`, emitted signal fields) surfaced in ACP `_meta.constellation`.
- **Phase 3 planned:** Deeper adaptive signaling hooks (compaction pressure, test-runner outcome tracking) and expanded multi-machine rollout.
- Legacy prototype files from the earlier graphical-console direction (`provider.zig`, `commands.zig`, `editor.zig`, `transcript.zig`, `surfaces.zig`, `integration.zig`, `tui.zig`, `console_runtime.zig`, `tui_render_tests.zig`) remain present on disk for now, **frozen and deferred**. Do not invest new feature work in the local console prototype.

## Rules

- Keep all Constellation-specific transport, signaling, and profile logic inside `src/constellation/`.
- No static hardcoded model catalogs or vendor OAuth flows — Constellation Router is the source of truth for models and upstream credentials.
- No secrets or API keys in logs, traces, or signaling payloads.
- Every file under `src/constellation/` is downstream-owned and excluded from the upstream patch-surface count (`scripts/patch-surface.sh`).
