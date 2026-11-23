# Vision

`cxn` is a lean, raw, Constellation-exclusive coding agent harness built as a disciplined upstream fork of `vercel-labs/fx`.

Its sole primary job is to live underneath **T3 Code** and connect exclusively to **Constellation Router** (`cxn-router`).

It is not a graphical terminal IDE. It is not an orchestrator. It is not a multi-vendor credential manager.

## The split

| Layer | Ownership | Purpose |
|---|---|---|
| Orchestration & UI | **T3 Code** (external) | Threads, worktrees, approvals, visual rendering, multi-agent coordination, linked machines (`apps01`) |
| Agent kernel | **Upstream (`vercel-labs/fx`)** | Agent loop, tools, sessions, permissions, MCP, skills, subagents, ACP JSON-RPC 2.0 server, Responses protocol |
| Constellation harness layer | **Downstream (`cxn`)** | Constellation-exclusive provider/transport, dynamic router catalog, ACP telemetry bridge, harness profiles, bidirectional workflow signaling |
| Inference control plane & runtimes | **Constellation Router (`cxn-router`)** | Model catalog, virtual routing workflows (`constellation/auto|smart|efficient`), seats, credentials, quotas, upstream provider runtimes |

The downstream layer must stay tightly isolated under `src/constellation/` behind thin registration hooks so upstream `vercel-labs/fx` merges stay cheap six months from now.

## Product identity

- **T3 Code** pilots the development workflow.
- **Constellation Router** abstracts upstream inference providers (Codex/OpenAI, Anthropic, xAI, Muse Code, Custom/Go, Cursor) and owns model selection, seats, and quotas.
- **`cxn`** unifies T3 Code's fragmented per-provider harnesses into one raw, fast native Zig harness dedicated to Constellation Router.
- **Strategic differentiator ("eating on both ends"):** Owning both the harness and the router enables **profiles** and **bidirectional structured signaling**. The harness can attach workflow and reasoning-complexity signals to requests so Constellation Router can route intelligently (e.g., selecting Muse Ember or GPT-6 Luna for medium-reasoning steps instead of spending frontier Opus capacity), while the router returns decision telemetry back to the harness and T3 Code.

## Design principles

1. **Raw harness first.** Start minimal. Inherit `fx`'s proven ACP server, tool suite, permissions, and durable sessions; add only the tailoring, transport, profiles, and signaling needed for Constellation Router and T3 Code.
2. **Router is the inference authority.** Never ship static model tables, vendor OAuth flows, or hidden routing heuristics inside `cxn`. Discover models dynamically from Constellation Router and treat harness signals as advisory inputs to router workflows.
3. **One unified harness on `apps01`.** Primary MVP is getting `cxn` deployed onto `apps01` and replacing the patchwork of per-vendor CLI harnesses under T3 Code.
4. **Small binary, fast startup, tiny patch surface.** Preserve `fx`'s ~7.8 MiB binary budget, sub-2ms cold-start discipline, and strict upstream patch-surface budget.
5. **Honest scope separation.** Never document Phase 2/3 signaling or profile capabilities as shipped until built and verified end-to-end.

## What `cxn` is not

- Not a fork that rewrites `fx` core internals for every feature.
- Not a graphical terminal console (Vim composer, Kitty graphics, mouse hit maps, Herdr nesting, embedded browser work in `PRD-003` through `PRD-007` is archived/deferred).
- Not an orchestrator or fleet manager (T3 Code owns threads, worktrees, and UI).
- Not a replacement for Constellation Router (the router owns upstream provider runtimes, credentials, and quota policy).

See [PRDs/PRD-008-constellation-t3-harness.md](PRDs/PRD-008-constellation-t3-harness.md) for the canonical specification and phased roadmap.
