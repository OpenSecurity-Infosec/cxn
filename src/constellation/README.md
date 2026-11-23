# src/constellation — downstream Constellation harness layer

All `cxn`-owned code lives here. Upstream `src/` files are touched only for thin registration points (provider registration, ACP option/metadata hooks, Constellation CLI defaults/subcommands). See [docs/PRDs/PRD-008-constellation-t3-harness.md](../../docs/PRDs/PRD-008-constellation-t3-harness.md) for the active specification and [docs/cxn/README.md](../../docs/cxn/README.md) for fork discipline.

## Active Sub-Areas (Target Layout per `PRD-008`)

```text
src/constellation/
  root.zig          Downstream module root and test aggregator
  provider/         Constellation Router HTTP/SSE client, dynamic `/models` catalog,
                    Bearer auth, correlation headers, RoutingMetadata parser,
                    and Constellation auto-mode permission reviewer
  signaling/        (Phase 2) Workflow-state analyzer, outbound signaling envelope,
                    and inbound router feedback consumer
  profiles/         (Phase 2) Profile config schema, loader, and CLI/ACP wiring
  acp_bridge/       Helpers for Constellation ACP configOptions & `_meta.constellation`
  cli/              `cxn status`, `cxn doctor`, `cxn models` snapshot/formatting helpers
```

## Current Stage

- `provider.zig` contains the initial pure-logic stubs (`Profile`, `RoutingMetadata`, `buildCatalog`) that will expand into `provider/` for `PRD-008` Phase 1.
- Legacy prototype files from the earlier graphical-console direction (`commands.zig`, `editor.zig`, `transcript.zig`, `surfaces.zig`, `integration.zig`, `tui.zig`, `console_runtime.zig`, `tui_render_tests.zig`) remain present on disk for now, **frozen and deferred**. Do not invest new feature work in the local console prototype.

## Rules

- Keep all Constellation-specific transport, signaling, and profile logic inside `src/constellation/`.
- No static hardcoded model catalogs or vendor OAuth flows — Constellation Router is the source of truth for models and upstream credentials.
- No secrets or API keys in logs, traces, or signaling payloads.
- Every file under `src/constellation/` is downstream-owned and excluded from the upstream patch-surface count (`scripts/patch-surface.sh`).
