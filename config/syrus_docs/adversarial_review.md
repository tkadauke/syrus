# Adversarial Review

Adversarial review adds an independent critic agent to the implementation loop. Before graders run, a separate agent reads the original issue and the implementation diff, then judges whether the changes address the requirements correctly and flags any problems it finds.

## How it works

When adversarial review is enabled (rounds > 0), Syrus inserts a bounded loop before the grader step chain. In the `initial` workflow, `implement` always runs first as a top-level step — implementation happens regardless of whether adversarial review or a grade loop are configured — so the loop itself is `review_first`:

```
implement → adversarial_review → implement → adversarial_review → ... → implement → graders
            ^ iteration 1         ^ iteration 2 (repair + review) ...   ^ final iteration (repair only)
```

- **Iteration 1** is `adversarial_review` alone, reviewing the top-level `implement`'s diff directly — there's no need to re-implement before the very first look.
- **Iterations 2 through (rounds − 1)** pair a repair `implement` with another `adversarial_review`, same as before.
- **The final iteration** (iteration `rounds`, reached only if the review budget runs out) is a repair `implement` with no trailing review. There's no iteration left to act on further feedback, so running the reviewer again would just be a no-op — the loop exits straight to grading once that last repair finishes.

Each `adversarial_review` call: a fresh agent (in a new session) reads the issue and the diff from the last `implement` step, then calls `submit_adversarial_review` with a verdict and findings. Any workspace changes the reviewer makes are discarded — the reviewer is read-only.

The loop runs for at most the configured number of rounds. After it exits (by approval or by exhausting the budget), the grader chain runs on the final committed state. In `initial` that grader chain is itself check-first — see [`workflow_steps.md`](workflow_steps.md) — so it doesn't re-implement again before grading; it only adds a repair `implement` back in if a grader iteration actually fails.

In `retry`, the agent step (`implement`) has no separate top-level run before the loop, so it uses the uniform shape instead: `implement → adversarial_review → implement → adversarial_review → ...`, with `implement` on every iteration including the first. The feedback workflows (`pr_comment`, `chat_feedback`, `external_pr_feedback`) use the same uniform loop shape with `respond` in place of `implement`.

## Verdicts

The reviewer agent must call the available `submit_adversarial_review` MCP tool name with one of two verdicts:

- **`approved`** — the implementation is acceptable. The loop records the findings and continues to the next step (or exits the loop if rounds are exhausted).
- **`needs_work`** — the implementation has problems. Findings are stored and fed back to the `implement` agent on the next iteration.

If the agent does not call the required `submit_adversarial_review` tool, the step fails with "agent didn't call submit_adversarial_review".

## Findings carry-forward

Findings accumulate in `workflow.artifacts["adversarial_review_iterations"]` as an array and appear in the workflow detail UI. Two separate consumers read that array:

- The **reviewer** itself gets every prior iteration's findings (regardless of verdict) via `prior_findings` in `Prompts::AdversarialReview`, so a later review round has context on what earlier rounds already flagged.
- The **repair `implement` agent** gets only the `needs_work` iterations, rendered by `Prompts::ReviewFeedback` and appended to its prompt (`Steps::Base#append_review_feedback`). This is what actually tells the implementing agent what to fix — without it, a repair iteration would just re-receive the original task prompt with no idea what the reviewer objected to.

## Configuration

### Instance-wide (AppSetting)

```ruby
AppSetting.current.update!(adversarial_review_rounds: 2)
```

Rounds range: 0–10. Default is 0 (disabled).

In `initial`, `rounds: 1` reviews the top-level `implement` exactly once. If that review comes back `needs_work`, there's no budget left for a repair iteration — the workflow proceeds to grading with the reviewer's feedback recorded but unaddressed. Set `rounds: 2` or higher to guarantee at least one repair pass.

### Per-repo (.syrus.yml)

```yaml
adversarial_review:
  rounds: 2
  criteria:
    - Verify all new endpoints enforce authentication
    - Check that database queries use parameterized inputs
    - Confirm error messages do not leak internal state
```

Per-repo configuration overrides the instance-wide setting. Set `rounds: 0` to disable for a specific repo even when the instance default is non-zero.

### criteria

`criteria` is an optional array of strings under the `adversarial_review` key. Each entry is a reviewer focus area specific to the repository — security patterns, API contracts, coding standards, or any concern the operator wants the reviewer to always check.

When `criteria` is present and non-empty, the reviewer prompt includes a "pay particular attention to the following criteria" section listing each item. These criteria supplement (not replace) the standard review checklist: the reviewer still checks for bugs, regressions, missing edge cases, and maintainability issues on top of any operator-provided criteria.

`criteria` is optional. Omitting it keeps existing behaviour. An empty array is valid. Blank entries are silently dropped.

## Session continuity

The adversarial reviewer resumes its session from the previous `adversarial_review` step in the same loop, so it has context from prior review iterations. It does not share a session with the `implement` agent — the separation is intentional to avoid anchoring bias.

## Which workflows include adversarial review

Adversarial review runs in `initial`, `retry`, `pr_comment`, `chat_feedback`, and `external_pr_feedback` workflows when rounds > 0. It does not run in `ci_failure`, `auto_merge`, or maintenance workflows (`rebase`, `stack_rebase`).

### Retry workflow

When adversarial review is enabled for a retry workflow, the loop runs before visual review and the grader retry chain:

```
implement → adversarial_review → ... → visual_review? → graders
```

Unlike `initial`, retry has no top-level `implement` step before the adversarial review loop. The first loop iteration therefore starts with `implement`, then runs `adversarial_review` against that diff.

### Feedback workflows (pr_comment, chat_feedback, external_pr_feedback)

When adversarial review is enabled for a feedback workflow, the loop runs before the grader retry chain:

```
respond → adversarial_review → ... → graders
```

The reviewer prompt includes:
- A note that this is a feedback workflow (not a fresh implementation)
- The full feedback history (PR comments or chat message) being addressed

The reviewer reads the `respond` step diff rather than an `implement` step diff, and has visibility into what feedback the agent was asked to handle.
