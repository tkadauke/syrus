# PR feedback classification and audit

Syrus reads PR and review comments in natural language: no `@syrus` mention or
command syntax is needed. Each ingested comment goes through two independent
stages, and both are recorded on the `pr_review_comments` row.

## Stage 1: is it a request for change?

`PrCommentIngester` first applies deterministic rules, then asks
`PrCommentClassifier` (a one-shot model judgment) for the rest.

| `classification_decision` | `classification_source` | Meaning |
|---|---|---|
| `actionable` | `model` | Model judged the comment a concrete change request |
| `not_actionable` | `model` | Praise, discussion, third-party commentary, hypothetical changes, etc. |
| `skipped_bot` | `rule` | Syrus report comment or bot account (`[bot]` / type `Bot`) |
| `quoted_only` | `rule` | Every line is a quote (`>`); no request of the author's own |
| `empty_body` | `rule` | Empty body, treated as actionable |
| `error` | `model` | Classifier failed or timed out; **fails closed** (not actionable). See `classification_error` |

`classification_reason` holds the model's one-line reason, and
`classifier_version` is `PrCommentClassifier::VERSION` (bump it when the prompt
changes materially).

## Stage 2: may it start work?

Authorization is evaluated independently of the model. A model "actionable"
verdict can never override it.

| `qualification_gate` | Meaning |
|---|---|
| `qualified` | Actionable and the author/policy gates passed (`qualified_for_workflow: true`) |
| `not_actionable` | Stage 1 rejected it |
| `unauthorized_author` | Actionable, but the author is external (and not a fork-review external) |
| `feedback_policy` | Actionable member comment, but the repository `feedback_policy` is not `auto` |

## Where to look

The Job detail payload and the pending-feedback API return a `classification`
object per comment (decision, reason, source, classifier_version, error,
qualified_for_workflow, qualification_gate). The comment body is intentionally
not duplicated into it. Comments ingested before this audit existed have empty
fields.
