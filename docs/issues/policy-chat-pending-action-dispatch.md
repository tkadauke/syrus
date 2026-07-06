# Refactor ChatPendingAction action dispatch to command objects

**Severity**: High — 20+ branches on an extensible string key; every new action requires touching three separate case statements.

## Problem

`ChatPendingAction` has three independent case statements all switching on the same `action_key` string:

### 1. `#execute` — lines 159–319 (`app/models/chat_pending_action.rb`)

```ruby
case action_key
when "cancel_job"
  # ...
when "retry_job"
  # ...
when "rebase_job"
  # ...
when "reopen_job"
  # ...
when "fire_scheduled_task_now"
  # ...
when "create_repo_document"
  # ...
when "delete_repo_document"
  # ...
when "poll_job_feedback"
  # ...
when "check_job_mergeability"
  # ...
when "delegate_issue"
  # ...
when "pause_landing_queue"
  # ...
when "resume_landing_queue"
  # ...
when "submit_chat_feedback"
  # ...
when "reopen_epic_and_attach_job"
  # ...
when "admin_kill_process"
  # ...
when "admin_reap_stale_runs"
  # ...
when "admin_pause_polling"
  # ...
when "admin_unpause_polling"
  # ...
when "admin_pause_runs"
  # ...
when "admin_unpause_runs"
  # ...
when "admin_clear_github_cache"
  # ...
when "admin_pause_user_scheduling"
  # ...
when "admin_unpause_user_scheduling"
  # ...
when "admin_retry_step"
  # ...
when "admin_cleanup_workspace"
  # ...
when "admin_refresh_installations"
  # ...
```

### 2. `#subject_for_notification` — lines 326–356 (`app/models/chat_pending_action.rb`)

```ruby
case action_key
when "cancel_job", "retry_job", "rebase_job", "reopen_job", "poll_job_feedback", "check_job_mergeability"
  # ...
when "fire_scheduled_task_now"
  # ...
when "create_repo_document"
  # ...
when "delete_repo_document"
  # ...
when "delegate_issue"
  # ...
when "submit_chat_feedback"
  # ...
when "reopen_epic_and_attach_job"
  # ...
when "admin_kill_process"
  # ...
when "admin_pause_user_scheduling", "admin_unpause_user_scheduling"
  # ...
when "admin_retry_step"
  # ...
when "admin_cleanup_workspace"
  # ...
when "schedule_recurring"
  # ...
```

### 3. `ChatPendingActionOutcomeNotification#notification_text` — lines 32–57 (`app/services/chat_pending_action_outcome_notification.rb`)

```ruby
case kind
when "cancel_job", "retry_job", "rebase_job", "reopen_job",
     "poll_job_feedback", "check_job_mergeability"
  # ...
when "reopen_epic_and_attach_job"
  # ...
when "fire_scheduled_task_now"
  # ...
when "create_repo_document"
  # ...
when "delete_repo_document"
  # ...
when "delegate_issue"
  # ...
when "admin_kill_process"
  # ...
when "admin_pause_user_scheduling", "admin_unpause_user_scheduling"
  # ...
when "admin_retry_step"
  # ...
when "admin_cleanup_workspace"
  # ...
when "schedule_recurring"
  # ...
```

## Why this matters

- Every new action requires finding and updating all three switch sites.
- The model has grown to handle unrelated concerns: job management, document CRUD, Epic operations, admin tasks. Each action's execution is mixed into one file.
- `ChatPendingActionOutcomeNotification` duplicates parts of the action registry with its own string matching, meaning notification behavior drifts from execution behavior.

## Target design

### Interface

```ruby
module PendingActions
  class Base
    def self.action_key
      raise NotImplementedError
    end

    def initialize(action, user:)
      @action = action
      @user = user
    end

    def execute
      raise NotImplementedError
    end

    def subject_for_notification
      nil
    end

    def outcome_text(outcome)
      "Action #{outcome}."
    end
  end
end
```

### Registry

```ruby
module PendingActions
  REGISTRY = {}.freeze

  def self.for(action_key)
    REGISTRY[action_key.to_s] || raise(UnknownAction, action_key)
  end

  def self.register(klass)
    REGISTRY[klass.action_key] = klass
  end
end
```

### Example handler

```ruby
# app/services/pending_actions/cancel_job.rb
module PendingActions
  class CancelJob < Base
    PendingActions.register(self)

    def self.action_key = "cancel_job"

    def execute
      job = Job.find(@action.payload.fetch("job_id"))
      # ... cancel logic
    end

    def subject_for_notification = job

    def outcome_text(outcome)
      outcome == :confirmed ? "Job cancelled." : "Job cancellation #{outcome}."
    end
  end
end
```

### Calling code

```ruby
# ChatPendingAction#execute becomes:
PendingActions.for(action_key).new(self, user: user).execute

# ChatPendingActionOutcomeNotification#notification_text becomes:
PendingActions.for(kind).new(action, user: user).outcome_text(outcome)
```

### Files to create

`app/services/pending_actions/base.rb` and one file per action kind, e.g.:
- `pending_actions/cancel_job.rb`
- `pending_actions/retry_job.rb`
- `pending_actions/rebase_job.rb`
- ... (one per existing `when` branch)

### Files to update

- `app/models/chat_pending_action.rb` — replace `#execute` and `#subject_for_notification` with registry lookup
- `app/services/chat_pending_action_outcome_notification.rb` — replace `#notification_text` case with registry lookup

## Out of scope

- Changing action payload shapes or the ChatPendingAction model schema
- Moving actions to a separate microservice
- Adding new actions as part of this refactor
- Renaming existing action_key strings (would break stored records)
- A full CQRS rewrite because the word "Command" sounds architecturally significant
