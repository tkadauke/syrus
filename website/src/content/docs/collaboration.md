---
title: Collaboration
description: Collaboration modes for solo operators, shared-repository teams, fork-based teams, and open source contributors.
---

# Collaboration

Syrus adapts to four collaboration patterns depending on who owns the
repository, whether the GitHub App is installed on it, and who else is
registered on the same Syrus instance. No explicit mode switch is required —
Syrus infers the right pattern from the repository and membership
configuration and applies the appropriate review policy, feedback policy, and
fork workflow automatically.

## Summary Table

| Dimension | Solo | Team — shared repo | Team — fork + upstream | Open source |
| --- | --- | --- | --- | --- |
| Working repository | Your own | Shared, members added via repository members | Your own fork | Your own fork |
| Upstream target | — | Same repository | Team-owned upstream | Maintainer-owned upstream |
| Fork review PR | — | — | Yes | Yes |
| Auto-merge | Yes | Yes (review policy gates it) | Yes (review policy gates upstream PR) | No |
| Review policy | `self` | `self` / `two_person` / `final_say` | `self` / `two_person` / `final_say` | Not applicable |
| Feedback policy | — | `auto` / `confirm` | `auto` / `confirm` | `auto` / `confirm` |
| Fork sync at prepare | — | — | Yes | Yes |
| GitHub identity | App or PAT | App or PAT | App on fork; PAT for upstream | App or PAT (fork only) |

## Mode 1 — Solo

The simplest pattern: you own the repository, no other members are registered, no upstream is configured.

### How it is detected

- The repository has no other registered members.
- No upstream owner or name is configured.

### Setup

1. Register the repository in Syrus (Owner/name, trigger label, default branch).
2. Install the GitHub App on the repository, or configure a personal access token with `repo` scope.
3. Label a GitHub issue with the repository trigger label (default: `syrus`), or create a direct Job.

No further collaboration configuration is needed.

### Job flow

1. Syrus detects the labeled issue and creates a Job.
2. The Initial workflow runs: `prepare → implement → graders → summarize → test_plan → pr_open`.
3. Syrus opens a PR against the default branch.
4. Auto-approval fires if graders pass and the repository's `auto_approve_mode` allows it.
5. The Job lands via auto-merge if `auto_merge_enabled` is on; otherwise you approve and merge manually.

### Review and approval

Because no other members exist, self-approval is the only meaningful policy. The review policy implicitly behaves as `self` — the Job owner may approve and land their own PR.

If `auto_merge_enabled` is off, approve the Job in the Syrus UI or merge the PR directly on GitHub.

### GitHub identity

Syrus uses the GitHub App installation if one is linked for the repository owner. If not, it falls back to your personal access token. The credential mode (`app` or `pat`) is recorded on the Job for audit.

---

## Mode 2a — Team, Shared Repository

Multiple Syrus users share one repository. Review policies gate landing so a second pair of eyes or a designated reviewer must sign off before Syrus merges.

### How it is detected

- The repository has at least one registered member in addition to the repository owner.
- No upstream is configured.

### Setup

1. Register the shared repository in Syrus.
2. Install the GitHub App, or provide a PAT with sufficient `repo` scope.
3. Add teammates as repository members via the repository settings panel.
4. Configure the review policy for the repository (see [Review policies](#review-policies)).
5. Configure the feedback policy if you want to control how teammate PR comments are handled (see [Feedback policies](#feedback-policies)).

### Job flow

1. Any member with the `developer` or `admin` role can label an issue or create a direct Job against the shared repository.
2. The Initial workflow runs and opens a PR.
3. Graders run. Auto-approval fires if the configured `auto_approve_mode` allows it.
4. The review policy applies: depending on policy, the Job owner, a second member, or a designated final-say member must approve before landing.
5. Syrus merges the PR via auto-merge once all policy conditions are satisfied.

### Review policies

| Policy | Who may approve | Landing gate |
| --- | --- | --- |
| `self` | The Job owner | Owner approval is sufficient |
| `two_person` | Any registered repository member | A second member (not the Job owner) must approve |
| `final_say` | A designated final-say member | The designated member must approve regardless of other approvals |

Configure the policy on the repository settings page. The `two_person` policy satisfies the second-approver requirement when a member clicks Approve in the Syrus UI or approves the pull request on GitHub.

### Feedback policies

| Policy | Behavior |
| --- | --- |
| `auto` | A new PR comment from a registered member immediately starts a `pr_comment` Workflow |
| `confirm` | A new PR comment creates a pending action; the Job owner must confirm before the workflow starts |

The `confirm` policy is useful when comments from multiple reviewers arrive in batches or when you want to consolidate feedback before Syrus acts on it.

### Approval signals

Syrus recognizes three approval signals for team repositories:

- **Syrus UI** — click Approve on the Job page.
- **GitHub review approval** — submit an Approving review on the pull request. Syrus records this as `github_review` approval and moves the Job forward when the review policy is satisfied.
- **GitHub PR merge** — if the PR is merged directly on GitHub outside of Syrus, the Job closes as `external_pr_merged`.

---

## Mode 2b — Team, Fork + Trusted Upstream

Each member works in their own fork. The upstream repository is team-owned and has the Syrus GitHub App installed. Syrus creates a fork review PR as a review artifact and, on approval, opens a PR against the upstream.

### How it is detected

- The Syrus repository has an upstream owner and name configured.
- The Syrus GitHub App is installed on the upstream repository.

### Setup

1. Fork the upstream repository into your GitHub account.
2. Register your fork in Syrus (Owner/name = your fork).
3. On the repository settings page, set **Upstream owner** and **Upstream name** to the team-owned upstream.
4. Install the Syrus GitHub App on the upstream repository.
5. Configure the review policy and feedback policy for the upstream.

### Job flow

1. Label an issue on your fork or create a direct Job.
2. At prepare time, Syrus syncs your fork's default branch with the upstream default branch (see [Fork sync](#fork-sync)).
3. The Initial workflow creates the feature branch and implementation on your fork.
4. Syrus opens a **fork review PR** on your fork (base: fork default branch, head: feature branch). This is the review artifact.
5. Graders run against the fork PR.
6. Auto-approval fires if the fork's `auto_approve_mode` and the review policy allow it.
7. On approval in the Syrus UI or via GitHub review on the fork PR, Syrus opens a **upstream PR** from your fork's feature branch against the upstream default branch.
8. The review policy (configured on the upstream repository) gates auto-merge of the upstream PR.
9. Syrus merges the upstream PR when the policy is satisfied.

### Review policies

The same review policy values as Mode 2a (`self`, `two_person`, `final_say`) apply, evaluated against the upstream repository's registered members.

### Feedback policies

The feedback policy applies to comments on the **upstream PR**. Upstream repository members' comments are the feedback signals.

| Policy | Behavior |
| --- | --- |
| `auto` | A new comment on the upstream PR from a registered upstream member starts a `pr_comment` Workflow |
| `confirm` | A new upstream PR comment creates a pending action; the fork owner must confirm |

### Fork sync

At the start of every prepare step, Syrus fetches the upstream default branch and rebases the fork's default branch onto it. This keeps implementations current with the upstream tip before a feature branch is created. The sync uses the upstream's authenticated URL (App credential if available, PAT otherwise).

### Approval signals

- **Syrus UI** — approve the Job (applies to the fork review PR and gates upstream PR creation).
- **GitHub review approval** — an approving review on the fork PR or the upstream PR counts as a review signal.
- **GitHub PR merge** — if the upstream PR is merged directly, the Job closes as `external_pr_merged`.

### GitHub identity

Syrus uses the App credential when pushing to the fork and when opening or updating the upstream PR. If the App is not installed on the fork, it falls back to the user's PAT for fork operations. The App must be installed on the upstream.

---

## Mode 3 — Open Source Contributor

Your fork targets an upstream you do not own, and the Syrus GitHub App is not installed on the upstream. Syrus creates a fork review PR for local review, then helps you open a PR against the upstream — but auto-merge is not available because the upstream maintainer controls merging.

### How it is detected

- The Syrus repository has an upstream owner and name configured.
- The Syrus GitHub App is **not** installed on the upstream repository.

### Setup

1. Fork the upstream repository into your GitHub account.
2. Register your fork in Syrus.
3. On the repository settings page, set **Upstream owner** and **Upstream name** to the upstream you are contributing to.
4. Make sure your personal access token can push to your fork and open PRs against the upstream.

No App installation on the upstream is needed or possible.

### Job flow

1. Label an issue on your fork or create a direct Job.
2. At prepare time, Syrus syncs your fork's default branch with the upstream default branch.
3. Syrus opens a **fork review PR** on your fork for local review.
4. Graders run. Auto-approval may fire based on the fork's `auto_approve_mode`.
5. You approve the Job in the Syrus UI (or via GitHub review on the fork PR).
6. Syrus opens a **PR against the upstream** from your fork's feature branch using your PAT.
7. The upstream maintainer reviews and merges the PR on GitHub. Syrus polls the upstream PR state.
8. When the upstream PR is merged or closed, the Job closes as `external_pr_merged` or `external_pr_closed`.

### Review policies

Review policies as defined for Mode 2a do not apply here because Syrus has no authority over the upstream review process. The upstream maintainer's GitHub review is the gating signal.

### Feedback policies

The feedback policy applies to comments from the upstream maintainer on the upstream PR.

| Policy | Behavior |
| --- | --- |
| `auto` | A new upstream PR comment triggers a `pr_comment` Workflow automatically |
| `confirm` | A new upstream PR comment creates a pending action; you must confirm before Syrus acts |

The `confirm` policy is especially useful for open source contributions where upstream maintainer feedback may need careful review before Syrus commits a follow-up.

### Approval signals

- **Syrus UI** — click Approve to authorize opening the upstream PR.
- **GitHub review approval** — an approving review on the fork PR counts as an internal approval signal and satisfies the `self` review check.
- **GitHub PR merge** — when the upstream maintainer merges the PR on GitHub, Syrus closes the Job as `external_pr_merged`.

There is no Syrus-controlled auto-merge for upstream PRs in this mode. The upstream maintainer has full control.

### Fork sync

Same as Mode 2b: Syrus syncs the fork's default branch with the upstream at prepare time. This uses your PAT, since the App is not installed on the upstream.

### GitHub identity

Syrus uses the App credential for fork operations when the App is installed on the fork. Upstream PR operations always use your personal access token, because the App is not installed there.

---

## Review Policies

Review policies are configured per repository on the repository settings page. They apply when a Job reaches the `implemented` state and is waiting for human sign-off before landing.

| Policy | Meaning |
| --- | --- |
| `self` | The Job owner's approval is sufficient. Use for solo work or high-trust teams. |
| `two_person` | A second registered member (not the Job owner) must approve before landing. |
| `final_say` | A specific designated member must approve. Other approvals do not count unless the designated member also approves. |

The `two_person` and `final_say` policies do not prevent other members from leaving feedback or commenting — they only gate the final landing step.

Approval can come from three sources:

1. **Syrus UI** — click Approve on the Job page.
2. **GitHub review** — submit an Approving review on the pull request.
3. **Auto-rule** — fires after graders pass if `auto_approve_mode` is set to `if_graders_pass` or `if_graders_pass_and_tagged_safe`.

When `two_person` or `final_say` is active, auto-rule approval counts as the Job owner's signal. A second manual approval is still required.

---

## Feedback Policies

Feedback policies control how Syrus handles new PR comments from team members or upstream maintainers.

| Policy | Trigger | When to use |
| --- | --- | --- |
| `auto` | Syrus starts a `pr_comment` Workflow immediately when new feedback arrives | Tightly collaborative teams where every comment should be actioned |
| `confirm` | New feedback creates a pending action card; the Job owner must click Confirm before the workflow starts | Reviewing feedback in batches, open source upstreams, or when you want to annotate comments before Syrus reads them |

The confirm UX appears in the Syrus Job page as a **Feedback received** pending action. The operator can read the raw comment, decide whether to act on it, confirm or dismiss. Dismissed feedback is recorded in the Job log.

Feedback from GitHub bots, CI checks, and users not registered in Syrus is ignored by both policies unless the PR poll classifies the sender as a relevant actor.

---

## Fork Sync

When a repository has an upstream configured (Modes 2b and 3), Syrus syncs the fork's default branch with the upstream at prepare time before creating the feature branch. The sync sequence is:

1. Fetch the upstream default branch through the authenticated upstream URL.
2. Fast-forward the fork's local default branch to the upstream tip.
3. Push the updated default branch to the fork remote.

If the fork's default branch has diverged from the upstream (for example, from a previous failed sync), Syrus rebases rather than fast-forwarding. A failed sync is logged as a prepare warning but does not block the workflow — the agent proceeds from the current fork tip and the prepare warning is visible on the workflow page.

---

## GitHub Identity

Syrus uses two credential paths for GitHub operations:

| Path | When used |
| --- | --- |
| **GitHub App** | When a Syrus GitHub App installation is linked to the repository owner. Used for cloning, pushing, opening PRs, and posting comments. Commits show the App bot identity. |
| **Personal access token (PAT)** | Fallback when no App installation exists, or always for cross-owner operations such as upstream PRs in Mode 3. Commits show the user's GitHub identity. |

The credential mode chosen at Job creation time (`app` or `pat`) is recorded on the Job and visible on the Job detail page. Follow-up Workflows (feedback, rebase, CI repair) reuse the same credential mode that was active when the Job was created.

For token requirements:

- **App installation** — needs `Contents` (read/write) and `Pull requests` (read/write) on the target repository. Syrus administrators link an App installation from the GitHub App settings panel.
- **PAT** — needs `repo` scope for private repositories or `public_repo` for public. Fine-grained PATs need repository access plus Contents and Pull requests read/write.

For credential setup, see [Per-User Settings](/docs/configuration#per-user-settings) and [GitHub App and PAT Behavior](/docs/features#github-app-and-pat-behavior).
