# PR feedback classification and audit

Syrus reads PR and review comments in natural language; no `@syrus` mention or
command syntax is needed. Each ingested comment goes through two independently
recorded stages.

## Stage 1: is it a request for change?

Deterministic rules handle bot comments, quoted-only comments, and empty
comments. A one-shot model judgment classifies the remainder as actionable or
not actionable and records a short reason. Classifier errors and timeouts fail
closed: they do not start work.

## Stage 2: may it start work?

Authorization is evaluated independently of the model. An actionable verdict
can never override it. Work starts only when the author is permitted and the
repository feedback policy allows automatic handling. Other actionable
feedback remains visible for operator review.

The Job detail and pending-feedback surfaces show the decision, reason, source,
classifier version or error, whether the feedback qualified, and the gate that
prevented it from starting work. Older comments may have no classification
audit data.
