# src/constellation — downstream Constellation harness layer

All `cxn`-owned code lives here. Upstream `src/` files are touched only for thin registration points (provider registration, ACP option/metadata hooks, Constellation CLI defaults/subcommands). See [docs/PRDs/PRD-008-constellation-t3-harness.md](../../docs/PRDs/PRD-008-constellation-t3-harness.md) for the active specification and [docs/cxn/README.md](../../docs/cxn/README.md) for fork discipline.

## Shipped Phase 1 Modules (`PRD-008`)

```text
src/constellation/
  root.zig                 Downstream module root and test aggregator
  runtime.zig              `cxn` invocation detection, public-infer-always base URL
                           (`https://infer.cxn.sh/api/v1`), API key/model env resolution,
                           and thread-safe per-session `RouteTelemetry` store
  transport.zig            Constellation Router OpenAI Responses API (`/responses`)
                           streaming transport matching `validatePublicBody`
  catalog.zig              Dynamic `/models` discovery provider (`model_catalog.Provider`
                           and `CliModelCatalogProvider`)
  permission_reviewer.zig  Constellation-exclusive `auto`-mode security reviewer
  bundle.zig               Exclusive Constellation `provider_set.Set` and `gateway_provider`
```

## Planned Phase 2 Modules (`PRD-008`)

```text
src/constellation/
  signaling/               Workflow-state analyzer, outbound signaling envelope,
                           and inbound router feedback consumer
  profiles/                Harness profile schema, loader, and CLI/ACP wiring
```

## Current Stage

- **Phase 1 MVP shipped:** Invoking the built binary as `cxn` (installed at `zig-out/bin/cxn`) activates Constellation-exclusive defaults (`https://infer.cxn.sh/api/v1`, `constellation/auto`, `CXN_API_KEY` or `FX_AUTH_MODE=host-managed`), dynamic `/models` discovery, Responses API tool-loop execution, Constellation-routed `auto` permission review, and ACP `agentInfo` / `configOptions` / `_meta.constellation` route telemetry.
- Legacy prototype files from the earlier graphical-console direction (`provider.zig`, `commands.zig`, `editor.zig`, `transcript.zig`, `surfaces.zig`, `integration.zig`, `tui.zig`, `console_runtime.zig`, `tui_render_tests.zig`) remain present on disk for now, **frozen and deferred**. Do not invest new feature work in the local console prototype.

## Rules

- Keep all Constellation-specific transport, signaling, and profile logic inside `src/constellation/`.
- No static hardcoded model catalogs or vendor OAuth flows — Constellation Router is the source of truth for models and upstream credentials.
- No secrets or API keys in logs, traces, or signaling payloads.
- Every file under `src/constellation/` is downstream-owned and excluded from the upstream patch-surface count (`scripts/patch-surface.sh`).
