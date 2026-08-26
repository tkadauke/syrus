# Plan: gh-stack native integration

_Companion to syrus#504 (branch parenting). Captured 2026-05-16._

_Status check 2026-08-26: GitHub stacked pull requests are now in public
preview, not private preview. The high-level mapping in this plan is still
relevant, but implementation should be revalidated against GitHub's current
Stacked PR docs/API surface before building against it._

## Context

GitHub announced [gh-stack](https://github.github.com/gh-stack/) — native
support for stacked PRs. The data model: a **stack** is a series of PRs
where each PR's base branch is the previous PR's branch (not `main`).
GitHub then layers on:

- Stack-map visualization in the PR UI
- Branch protection that targets the *final* base across the whole chain
- One-click cascading rebase
- Multi-PR merge that auto-rebases the remaining PRs

As of July 30, 2026 GitHub describes stacked pull requests as **public
preview**. GitHub's quickstart still says the feature is subject to change, so
Syrus should treat native integration as an adapter with explicit capability
detection rather than as a permanently stable API.

PR #495 ("Stacked diffs: auto-merge gates on parent + PR body stack
footer") implemented this in-house: `JobStackResolver`, `PrStackFooter`,
`StackRebaseCoordinator`, `PollMergeStateJob`. That code maps almost
1:1 onto what gh-stack provides natively. The in-house path becomes
the fallback for repos that haven't enabled gh-stack; native takes over
where it's available.

This plan covers the dispatching shape, not the load-bearing prerequisite
(branch parenting — syrus#504) without which neither path works.

## Direct mapping

| In-house (PR #495) | gh-stack native |
|---|---|
| `JobStackResolver` (parent/child computation) | implicit from branch base-of relationships |
| `PrStackFooter` (PR body footer with stack) | stack map in GitHub UI |
| `StackRebaseCoordinator` (cascading rebase) | one-click cascading rebase |
| `PollMergeStateJob` (watch for parent merge) | multi-PR merge / auto-rebase on merge |
| `steps/auto_merge.rb` waits for parent | branch protection enforces final base |

## Proposal: per-repo opt-in dispatching

### Schema

```sql
ALTER TABLE repositories
  ADD COLUMN gh_stack_enabled BOOLEAN NOT NULL DEFAULT FALSE;
```

Default off — only flip when the repository's GitHub account and desired
workflow are ready to rely on the public-preview behavior.

### UI

Add the flag to the repo edit form under "Advanced" with hint text:

```
GitHub stacked PRs (gh-stack)   [ ]
  Enable when this repo is ready to rely on GitHub's public-preview
  stacked PR behavior. When on, Syrus relies on GitHub's native stack handling
  (cascading rebase, multi-PR merge) instead of its in-house
  coordination. Requires branch parenting (syrus#504) to be active —
  no effect on its own.
```

### Dispatch logic per touch point

**`steps/auto_merge.rb`**:

- If `gh_stack_enabled`: use `merge_method: :auto_stack` (or whatever
  the native API surfaces once documented) to merge the whole stack
  in one call.
- Else: existing behavior (wait for parent merge, then merge child).

**`StackRebaseCoordinator`**:

- If `gh_stack_enabled`: skip. GitHub handles cascading rebase when an
  ancestor moves.
- Else: existing behavior (Syrus drives the rebase).

**`PollMergeStateJob`**:

- The "parent just merged → unblock children" responsibility moves to
  GitHub. The Job can keep doing other things (e.g. tracking the parent
  Job's merge state for our own UI / metrics), but the rebase trigger
  step is skipped for `gh_stack_enabled` repos.

**`PrStackFooter`**:

- Keep rendering it unconditionally. It's a few KB of text in the PR
  body, can't hurt, and gives reviewers context even when GitHub's
  stack map is right there. Revisit only if it becomes noise.

**`PullRequestOpener`**: no change here — branch parenting (syrus#504)
already sets the right `base` regardless of `gh_stack_enabled`.

### What we deliberately *don't* do

- **Don't shell out to `gh stack` CLI.** It's a local-developer tool;
  Syrus is running as a service. The CLI duplicates what we already
  do (push branches, open PRs).
- **Don't call gh-stack's REST/GraphQL API directly.** The surface
  isn't documented in the preview. Wait until GA.
- **Don't auto-detect `gh_stack_enabled`.** GitHub doesn't expose a
  read-side flag for which repos have the preview. The admin flips
  it manually.
- **Don't delete the in-house code.** It's the fallback for repos
  without gh-stack access, which will be most repos for the foreseeable
  future. Eventually deprecate when gh-stack is GA and ubiquitous.

## Rollout

Three commits, each independently reversible:

1. **Schema** — add `repositories.gh_stack_enabled`. No behavior change.
2. **Dispatch plumbing** — branch on the flag inside `auto_merge`,
   `StackRebaseCoordinator`, and the bits of `PollMergeStateJob` that
   schedule cascading rebases. Keep the in-house path as the `else`.
3. **UI** — surface the toggle in the repo edit form.

Depends on syrus#504 (branch parenting) being merged first. Without
that, the flag has nothing to dispatch on — GitHub doesn't see a stack
in the first place.

## Validation

Once a target repo gets gh-stack preview access:

1. Set `gh_stack_enabled = true` on that Repository.
2. File two issues where one says `Depends-on: #<other>`.
3. Both Jobs ingest. The second Job's branch should target the first
   Job's branch (syrus#504), and GitHub's UI should show the stack map.
4. Merge the parent PR. GitHub should rebase the child automatically;
   Syrus's `StackRebaseCoordinator` should *not* fire (verifiable via
   logs).
5. Merge the child PR.

## Acceptance

- [ ] `repositories.gh_stack_enabled` column with default false
- [ ] Repo edit form exposes the toggle with documentation
- [ ] `auto_merge`, `StackRebaseCoordinator`, and `PollMergeStateJob`
      branch on the flag; in-house path unchanged when off; native path
      used when on
- [ ] Spec coverage for both flag values across all three touch points
- [ ] `ARCHITECTURE.md` updated to document the flag and the
      decision tree
- [ ] Validation steps run on a real preview-enabled repo before
      enabling for broader use

## Out of scope

- Branch parenting itself (syrus#504)
- Migrating away from the in-house stack code (premature; revisit when
  gh-stack is GA)
- gh-stack CLI integration (`gs init` / `gs add`) — not how Syrus
  operates
- gh-stack-specific UI elements in Syrus's own dashboards (GitHub's UI
  is the source of truth when `gh_stack_enabled`; the existing Syrus
  dependency-graph view stays as-is)

## Cross-references

- syrus#504 — branch parenting (load-bearing prerequisite)
- PR #495 — in-house stacked-diffs work (becomes fallback path)
- Roadmap: "Multiple PRs per issue" — touches the same domain
- [gh-stack docs](https://github.github.com/gh-stack/) — upstream
- Waitlist: join for `tkadauke/syrus` and any other repos likely to use
  stacked diffs in anger, so the flag has somewhere to flip to
