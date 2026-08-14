# Visual Review

Visual review gives the worker agent a headless browser it can drive
against its own in-step preview to catch visible defects — broken layout,
missing content, console errors, incorrect rendering, broken interactions —
before graders run. An independent reviewer agent forms its own go/no-go
judgment, exercises the running app, captures "after" screenshots as
Workflow artifacts, and records a verdict that can send the change back
for another implementation pass.

## Feature flag

Visual review is gated by the `visual_review` Labs feature flag
(`config/features.yml`), off by default. Enable it from Admin → Features,
or via Rails console:

```ruby
Feature.find_by(slug: "visual_review").update(enabled: true)
```

`Feature.visual_review_enabled?` is the instance-wide default that applies
whenever a repository hasn't set its own `.syrus.yml` `visual_review.enabled`
override (see [`syrus_yml.md`](syrus_yml.md)). Enabling the flag turns
visual review on for every repository that doesn't explicitly opt out;
it does not by itself require any per-repo configuration.

## How it works

When visual review is enabled and configured with `rounds > 0`, Syrus
inserts a bounded loop immediately after the `adversarial_review` loop and
before the grader retry loop:

```
implement → visual_review → implement → visual_review → ... → graders
```

(`respond → visual_review → ...` in feedback workflows.) Each iteration:

1. **implement**/**respond** — the agent writes or revises the code and commits.
2. **visual_review** — a fresh agent (in a new session) independently decides
   whether the change is visually testable, drives a headless browser against
   its own `start_preview` instance if so, captures screenshots, and calls
   `submit_visual_review` with a verdict and critique. Any workspace changes
   the reviewer makes are discarded — the reviewer is read-only.

Before spending an agent turn, a deterministic pre-filter can skip the step
outright: if `.syrus.yml` sets `visual_review.when_files_changed` and none of
the files changed since the default branch match, the step records a
`skipped` verdict without ever invoking the agent (mirrors a grader's
`when_files_changed`).

When the agent does run, it reads the `submit_test_plan` artifact's
`visual_review_recommended` / `visual_review_reason` fields — set by the
implementing agent as a hint about whether this change is worth visually
testing — but makes its own independent call before ever starting a preview.
This is a three-layer gate: the glob pre-filter (deterministic, no agent
turn), the implementer's hint (informational only), and the reviewer's own
judgment (authoritative).

## Verdicts

The reviewer agent must call `submit_visual_review` with one of three
verdicts:

- **`approved`** — the change looks correct. Exits the loop the same as
  `skipped`.
- **`needs_work`** — the reviewer found a visible defect. Findings are
  stored and fed back to the `implement`/`respond` agent on the next
  iteration, the same way `adversarial_review`'s `needs_work` does.
- **`skipped`** — the change isn't visually testable (invisible/backend-only
  diff, tests, docs, non-UI config). Exits the loop without treating it as a
  failure.

If the agent does not call `submit_visual_review`, the step fails with
"agent didn't call submit_visual_review".

Findings accumulate in `workflow.artifacts["visual_review_iterations"]` and
are passed to the implementing agent on later iterations via
`prior_findings`, the same carry-forward pattern `adversarial_review` uses.

## Configuration (`.syrus.yml`)

```yaml
visual_review:
  enabled: true
  rounds: 2
  when_files_changed:
    - "app/frontend/**/*"
    - "app/views/**/*"
  seed_notes: "Log in as demo@example.com / password to reach the dashboard."
```

- **`enabled`** — explicitly turns visual review on (`true`) or off
  (`false`) for this repository, overriding the instance-wide `visual_review`
  Feature flag default. Omitting the key (or the whole block) defers to
  `Feature.visual_review_enabled?`.
- **`rounds`** — how many visual-review passes run. Range 0–10, default 1.
- **`when_files_changed`** — optional glob patterns; when present, visual
  review only runs when at least one changed file matches. Same semantics as
  a grader's `when_files_changed`. Omitting it runs visual review regardless
  of which files changed.
- **`seed_notes`** — optional free text describing how to reach an
  authenticated or populated state in the preview app. Read by the reviewer
  agent as a hint, not executed.

See [`syrus_yml.md`](syrus_yml.md) for the full `.syrus.yml` reference.

## Seeding requirements

The reviewer drives the same in-step preview `start_preview`/`stop_preview`
tools spawn (see [`preview_environments.md`](preview_environments.md)). A
preview boots from a fresh checkout on every run, so reaching an
authenticated or populated view depends on the repository's preview `seed`
command being idempotent and producing demo data. The "Seed preview demo
data" Job template
(`lib/agent_skills/configure-preview-seed-data.md`) is a one-time, per-repo
onboarding pass that makes the seed mechanism idempotent, adds a demo
user and representative sample data if the repo has none, and records how
to reach that state in `visual_review.seed_notes`. Repositories that skip
this onboarding still get a running preview, but the reviewer agent may
only ever see an unauthenticated or empty-state app. If the documented seed
notes don't cover the feature under test, the reviewer agent may run
additional ad hoc seed commands itself via its normal shell access before
driving the browser.

## The browser tool set

The reviewer's browser tools are provided by the `browser` plugin
(`plugins/browser/`), a granular MCP tool set — `browser_navigate`,
`browser_snapshot`, `browser_click`, `browser_fill`, `browser_screenshot`,
`browser_wait_for`, `browser_close` — rather than one opaque "run test
suite" tool, so the agent improvises its own test plan against the running
preview. Each call is proxied to a per-Run `@playwright/mcp` subprocess.

**Loopback restriction.** `browser_navigate` is hard-restricted to the
worker's own loopback preview (`SyrusBrowser::LoopbackGuard`): only literal
`localhost`, `::1`, or `127.x.x.x` hostnames are accepted, over `http`/
`https`. Any other host is rejected before the browser is touched. This is
enforced in the tool handler, not just in the agent's prompt, so a
malicious or confused navigate call can't turn the agent's headless browser
into an SSRF or exfiltration path — the agent driving a real Chromium
instance can only ever reach the app `start_preview` started, never an
arbitrary URL on the network or public internet. The guard is deliberately
string-based rather than DNS-based: resolving a hostname and checking
whether it resolves to loopback is vulnerable to DNS rebinding (a name that
answers `127.0.0.1` at check time and something else when Chromium actually
connects), so only a small, fixed set of literal loopback spellings is
allowed.

## Screenshot artifacts

The reviewer captures "after" screenshots with `submit_visual_artifact`, an
image-capable sibling of `submit_artifact`: it accepts base64-encoded image
bytes (PNG/JPEG/WebP, up to 10 MB), persists them as an ActiveStorage blob
on the current Workflow, and records a `typed_artifacts` entry that the job
detail UI's Artifacts tab renders through the `:image_diff` renderer so
operators can see what the reviewer actually tested.

## Manual "Run visual review" trigger

Operators can run visual review on demand — for a fresh look after
implementation, or to cover a pass that was skipped or never configured —
without waiting for a new implementation. The Job detail page exposes a
"Run visual review" action (and chat exposes the equivalent
`run_visual_review` pending action) on implemented or approved Jobs with no
active run, gated by the same `RepoVisualReviewPlan` resolution the
automatic loop uses — the action is unavailable if visual review isn't
configured/enabled for the repository. This dispatches a standalone
`manual_visual_review` Workflow (`Workflows::ManualVisualReview`) that runs
the reviewer alone against whatever is already on the branch. Unlike the
automatic loop, it does not loop back into `implement`/`respond` on
`needs_work` — the verdict and critique are recorded on the workflow the
same way an automatic pass records them, for the operator to read and act
on manually.

## Which workflows include visual review

The automatic visual_review loop runs in `initial`, `retry`, `pr_comment`,
and `chat_feedback` workflows when visual review resolves enabled and
`rounds > 0`. It does not run in `ci_failure`, `auto_merge`, or maintenance
workflows (`rebase`, `stack_rebase`). The manual trigger's standalone
`manual_visual_review` Workflow is available independently of those chains
wherever the Job state and repository configuration allow it.

### Feedback workflows (pr_comment, chat_feedback)

When visual review is enabled for a feedback workflow, the loop runs after
the `adversarial_review` loop and before the grader retry chain:

```
respond → visual_review → ... → graders
```

The reviewer prompt includes a note that this is a feedback workflow and the
full feedback history (PR comments or chat message) being addressed, and
reads the diff from the `respond` step rather than an `implement` step.
