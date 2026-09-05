# Adversarial Review

Adversarial review adds an independent critic agent to the implementation loop. Before graders run, a separate agent reads the original issue and the implementation diff, then judges whether the changes address the requirements correctly and flags any problems it finds.

## How it works

When adversarial review is enabled (rounds > 0), Syrus inserts a bounded, review-first loop before the grader step chain. Every workflow that has this loop (`initial`, `retry`, `pr_comment`, `chat_feedback`, `external_pr_feedback`) leads with a bare top-level `implement`/`respond` step — implementation or feedback-response happens regardless of whether adversarial review or a grade loop are configured — so the loop itself always starts with the reviewer, never a redundant repeat of that work:

```
adversarial_review(1)
  approved         → exits the loop, findings carry forward but no repair needed
  needs_work       → implement/respond (repair), then, if rounds allow another
                      review after it, adversarial_review(2) → repeat the same decision
```

- **A `needs_work` verdict always gets a repair reaction** — the corresponding `implement`/`respond` step is inserted unconditionally, regardless of remaining review budget. This is the fix for a defect where a `needs_work` verdict at `rounds: 1` used to produce zero repair attempts.
- **The repair pairs with another review whenever budget remains** — iteration N's repair is followed by review N+1 as long as N was not the last round `rounds` allows.
- **Once the review that just ran was the last one `rounds` allows**, its `needs_work` repair runs alone, with no trailing review — there's no budget left to act on further feedback, so the loop exits straight to grading once that last repair finishes.

`rounds: N` means exactly N review opinions get sought; every one of them — including the last — gets exactly one repair reaction. The loop never ends on an unreacted-to `needs_work`, and it never fails the workflow on its own (unlike the grader retry loop, which genuinely can exhaust its budget and fail).

Worked out for `rounds: 1, 2, 3` (worst case: every review says `needs_work`):

| rounds | materialized sequence |
| --- | --- |
| 1 | `review(1)` → `implement` → stop |
| 2 | `review(1)` → `implement` → `review(2)` → `implement` → stop |
| 3 | `review(1)` → `implement` → `review(2)` → `implement` → `review(3)` → `implement` → stop |

Each `adversarial_review` call: a fresh agent (in a new session) reads the issue and the diff from the last `implement`/`respond` step, then calls `submit_adversarial_review` with a verdict and findings. Any workspace changes the reviewer makes are discarded — the reviewer is read-only.

After the loop exits (by approval or by exhausting the budget), the grader chain runs on the final committed state. In `initial`, `retry`, `pr_comment`, and `chat_feedback` that grader chain is itself check-first — see [`workflow_steps.md`](workflow_steps.md) — so it doesn't re-run `implement`/`respond` again before grading; it only adds a repair step back in if a grader iteration actually fails. `external_pr_feedback`'s grader chain is check-first too, for the same reason, even though it has no `.syrus.yml`-driven format/generate config to apply.

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

`rounds: 1` seeks exactly one review opinion. If that review comes back `needs_work`, it still gets a repair reaction — the reviewer's feedback is always addressed by a repair `implement`/`respond`, it just doesn't get reviewed a second time since the budget is exhausted after one opinion. Set `rounds: 2` or higher to have the repair reviewed again before grading.

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

`retry` has the same shape as `initial`: a bare top-level `implement` step, then, when enabled, the review-first adversarial review loop before visual review and the grader retry chain:

```
implement → adversarial_review(1) → [implement → adversarial_review(2) → ...] → visual_review? → graders
```

### Feedback workflows (pr_comment, chat_feedback, external_pr_feedback)

These workflows lead with a bare top-level `respond` step, the same way `initial`/`retry` lead with `implement`. When adversarial review is enabled, the loop runs before the grader retry chain, review-first:

```
respond → adversarial_review(1) → [respond → adversarial_review(2) → ...] → graders
```

The reviewer prompt includes:
- A note that this is a feedback workflow (not a fresh implementation)
- The full feedback history (PR comments or chat message) being addressed

The reviewer reads the `respond` step diff rather than an `implement` step diff, and has visibility into what feedback the agent was asked to handle.
