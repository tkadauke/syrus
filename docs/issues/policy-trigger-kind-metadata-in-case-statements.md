# Move trigger-kind metadata into Workflow::TriggerKind registry

**Severity**: Medium — trigger kinds are extensible (new workflow types keep appearing), but label and history-classification logic lives in service case statements instead of the registry where CLAUDE.md says it belongs.

## Problem

Two services switch on `trigger_kind` to produce UI metadata. Both belong in the `Workflow::TriggerKind` registry.

### 1. `JobRetryActions#retry_label` — lines 76–86 (`app/services/app/job_retry_actions.rb`)

```ruby
case latest_workflow.trigger_kind
when "auto_merge"
  "Retry landing step"
when "merge_train"
  # "Rebuild merge train" or "Retry merge train step"
when "rebase", "stack_rebase"
  "Retry rebase step"
else
  "Retry failed step"
end
```

### 2. `JobDetailPayload#feedback_history` — lines 347–360 (`app/services/app/job_detail_payload.rb`)

```ruby
case workflow.trigger_kind
when "chat_feedback"
  # extract feedback text from chat artifacts
when "pr_comment"
  # extract PR comment text from artifacts
end
```

## Why this matters

CLAUDE.md's Conventions section explicitly states:

> **Workflow/Step registries** — `Workflow::TriggerKind` and `Step::Kind` are the single source for trigger/step metadata: valid values, handler or template class, UI label/style, and whether a step is agentic. Add new trigger kinds or step kinds there instead of scattering constants in helpers/services.

Both of these cases are exactly what the registry is for: associating a trigger kind with UI metadata. Today they're scattered.

When a new trigger kind is added:
1. The developer adds it to `Workflow::TriggerKind`.
2. They *also* have to find these service files and update the case statements — or they don't, and the UI falls back to defaults that may not make sense.

## Target design

### Extend `Workflow::TriggerKind` with metadata

```ruby
# app/models/workflow/trigger_kind.rb
module Workflow
  module TriggerKind
    DEFINITIONS = {
      "initial"       => { retry_label: "Retry failed step",   feedback_kind: nil },
      "pr_comment"    => { retry_label: "Retry failed step",   feedback_kind: :pr_comment },
      "chat_feedback" => { retry_label: "Retry failed step",   feedback_kind: :chat_feedback },
      "ci_failure"    => { retry_label: "Retry failed step",   feedback_kind: nil },
      "retry"         => { retry_label: "Retry failed step",   feedback_kind: nil },
      "auto_merge"    => { retry_label: "Retry landing step",  feedback_kind: nil },
      "merge_train"   => { retry_label: nil,                   feedback_kind: nil }, # computed
      "rebase"        => { retry_label: "Retry rebase step",   feedback_kind: nil },
      "stack_rebase"  => { retry_label: "Retry rebase step",   feedback_kind: nil },
      # ...
    }.freeze

    def self.retry_label_for(trigger_kind, step_kind: nil)
      DEFINITIONS.fetch(trigger_kind.to_s, {})[:retry_label] || "Retry failed step"
    end

    def self.feedback_kind_for(trigger_kind)
      DEFINITIONS.fetch(trigger_kind.to_s, {})[:feedback_kind]
    end
  end
end
```

### Update callers

```ruby
# JobRetryActions
label = Workflow::TriggerKind.retry_label_for(latest_workflow.trigger_kind, step_kind: failed_step&.kind)

# JobDetailPayload
feedback_kind = Workflow::TriggerKind.feedback_kind_for(workflow.trigger_kind)
case feedback_kind
when :chat_feedback then # ...
when :pr_comment    then # ...
end
```

The `merge_train` retry label has conditional logic (varies by step kind). That can live in the registry method rather than the calling service.

## Out of scope

- Changing the trigger kind strings themselves
- Merging `Workflow::TriggerKind` with `Step::Kind`
- Any UI label changes beyond what's needed to wire through the registry
