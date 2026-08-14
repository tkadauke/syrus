# Adversarial Review

Adversarial review adds an independent critic agent to the implementation loop. Before graders run, a separate agent reads the original issue and the implementation diff, then judges whether the changes address the requirements correctly and flags any problems it finds.

## How it works

When adversarial review is enabled (rounds > 0), Syrus inserts a bounded loop before the grader step chain:

```
implement → adversarial_review → implement → adversarial_review → ... → graders
```

Each iteration:

1. **implement** — the agent writes or revises the code and commits.
2. **adversarial_review** — a fresh agent (in a new session) reads the issue and the diff from the last `implement` step, then calls `submit_adversarial_review` with a verdict and findings. Any workspace changes the reviewer makes are discarded — the reviewer is read-only.

The loop runs for the configured number of rounds. After all rounds complete, the grader chain runs on the final committed state.

## Verdicts

The reviewer agent must call the available `submit_adversarial_review` MCP tool name with one of two verdicts:

- **`approved`** — the implementation is acceptable. The loop records the findings and continues to the next step (or exits the loop if rounds are exhausted).
- **`needs_work`** — the implementation has problems. Findings are stored and fed back to the `implement` agent on the next iteration.

If the agent does not call the required `submit_adversarial_review` tool, the step fails with "agent didn't call submit_adversarial_review".

## Findings carry-forward

All findings from prior rounds are passed to the `implement` agent on subsequent iterations via `prior_findings` in the prompt. This means each implement iteration has visibility into what the reviewer found wrong in the previous attempt.

Findings are accumulated in `workflow.artifacts["adversarial_review_iterations"]` as an array. They appear in the workflow detail UI.

## Configuration

### Instance-wide (AppSetting)

```ruby
AppSetting.current.update!(adversarial_review_rounds: 2)
```

Rounds range: 0–10. Default is 0 (disabled).

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

### Feedback workflows (pr_comment, chat_feedback, external_pr_feedback)

When adversarial review is enabled for a feedback workflow, the loop runs before the grader retry chain:

```
respond → adversarial_review → ... → graders
```

The reviewer prompt includes:
- A note that this is a feedback workflow (not a fresh implementation)
- The full feedback history (PR comments or chat message) being addressed

The reviewer reads the `respond` step diff rather than an `implement` step diff, and has visibility into what feedback the agent was asked to handle.
