# Repository Strategy

## Topology

```text
vercel-labs/fx (upstream)
      │
      │ upstream sync
      ▼
origin/upstream-main        ← boring upstream mirror (no direct commits)
      │
      │ merge upstream-main -> main periodically
      ▼
origin/main                 ← shipping downstream `cxn` trunk
      │
      ├── feat/constellation-provider   (post-MVP feature branching)
      ├── feat/constellation-acp-mvp
      ├── feat/apps01-deploy
      ├── feat/profiles-signaling
      └── ...
```

- `upstream-main` tracks Vercel (`vercel-labs/fx` `main`). No Constellation features land here.
- `main` is the active downstream trunk for `cxn`. During the Phase 1 MVP push, work lands directly on `main`; once MVP is reached, return to short-lived feature branches forking from and merging back into `main`.
- Merge `upstream-main -> main`. Never repeatedly rewrite the long-lived downstream trunk. Rebase short-lived feature branches only.

Current remotes already match this: `upstream` is `vercel-labs/fx`, `origin` is the downstream fork.

## Patch-surface KPI

> downstream patch surface = number of upstream-owned files modified by Constellation relative to `upstream-main`

Track it in CI. It must stay small. Growth from ~12 to 70 to 250 files means upstream merges are becoming painful and the architecture has failed.

Rules:

- Prefer `src/constellation/` plus thin hooks over edits inside `src/core/`, `src/acp/`, `src/gateway/`, `src/ui/`.
- Every upstream-owned touch is labeled `upstreamable` or `downstream-hook` in the PR description.
- Prefer adopting upstream PRs (e.g. OpenAI-compatible/Responses provider work and ACP hardening) over carrying duplicate transports.

## Sync automation (PRD-001 scope)

- Scheduled or on-demand sync job: fetch upstream, fast-forward `upstream-main`, open `upstream-main -> main` merge PR.
- Upstream compatibility CI: build + focused tests on the merge before it lands.
- Corpus discipline: every root `tests/e2e/*.test.ts` keeps exactly one PGSO classification in `scripts/pgso/corpus.json` (`training`, `verification-only`, `intentional-exclusion`). New E2E owners reconsider classification. Removals delete stale entries.

## Branch practice

- Pre-MVP (Phase 1): unified development on `main` to reach MVP fast without branch churn.
- Post-MVP: feature branches fork from `main`, merge back into `main`.
- Checkpoint commits stay clean so Full CI maps to the exact commit.
- PR titles are clean imperative sentences. `type:` label is required (`bug`, `feature`, `improvement`, `docs`, `maintenance`, `release`, `security`).
