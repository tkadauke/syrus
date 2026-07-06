# Refactor pr_pileup_policy dispatch to follow the ReviewPolicies pattern

**Severity**: Medium — 3 branches on an extensible policy string; `review_policy` already has a clean registry-based hierarchy; `pr_pileup_policy` should match it.

## Problem

`ScheduledTaskFire#call` switches on `pr_pileup_policy` inline (`app/services/scheduled_task_fire.rb`, lines 35–44):

```ruby
case @task.pr_pileup_policy
when "skip"
  if @task.has_open_pr?
    @task.record_fire!(at: @now)
    return Result.new(job: nil, skipped: true, reason: "prior_pr_open")
  end
when "replace"
  close_prior_open_prs
when "pile"
  # fall through
end
```

Three policy values (`skip`, `replace`, `pile`) are defined on both `cron_templates` and `scheduled_tasks` tables (default `"skip"`). Adding a fourth policy value (e.g., `"close_stale"` — close PRs older than N days) would require adding a new `when` branch here and remembering to update `ScheduledTask#PR_PILEUP_POLICIES`, the UI, and any serializer that displays it.

## Why this matters

`review_policy` has exactly this problem solved already. `ReviewPolicies.for(policy_name).new(job).satisfied?` is the pattern. `pr_pileup_policy` should use the same shape.

## Target design

### Registry module

```ruby
# app/services/pr_pileup_policies.rb
module PrPileupPolicies
  REGISTRY = {
    "skip"    => "PrPileupPolicies::SkipPolicy",
    "replace" => "PrPileupPolicies::ReplacePolicy",
    "pile"    => "PrPileupPolicies::PilePolicy",
  }.freeze

  def self.for(name)
    class_name = REGISTRY[name.to_s] or raise ConfigurationError, "Unknown pr_pileup_policy: #{name}"
    class_name.constantize
  end

  ConfigurationError = Class.new(StandardError)
end
```

### Shared interface

```ruby
# app/services/pr_pileup_policies/base.rb
module PrPileupPolicies
  class Base
    def initialize(task, fire_service:)
      @task = task
      @fire_service = fire_service
    end

    # Returns a Result if the policy aborts the fire, nil if fire should proceed.
    def check_pileup
      raise NotImplementedError
    end
  end
end
```

### Policy subclasses

```ruby
# app/services/pr_pileup_policies/skip_policy.rb
module PrPileupPolicies
  class SkipPolicy < Base
    def check_pileup
      return unless @task.has_open_pr?
      @task.record_fire!(at: @fire_service.now)
      ScheduledTaskFire::Result.new(job: nil, skipped: true, reason: "prior_pr_open")
    end
  end
end

# app/services/pr_pileup_policies/replace_policy.rb
module PrPileupPolicies
  class ReplacePolicy < Base
    def check_pileup
      @fire_service.close_prior_open_prs
      nil
    end
  end
end

# app/services/pr_pileup_policies/pile_policy.rb
module PrPileupPolicies
  class PilePolicy < Base
    def check_pileup = nil  # always proceed
  end
end
```

### Updated caller

```ruby
# ScheduledTaskFire#call
policy = PrPileupPolicies.for(@task.pr_pileup_policy).new(@task, fire_service: self)
result = policy.check_pileup
return result if result
# ... proceed with job creation
```

### Files to create

- `app/services/pr_pileup_policies.rb`
- `app/services/pr_pileup_policies/base.rb`
- `app/services/pr_pileup_policies/skip_policy.rb`
- `app/services/pr_pileup_policies/replace_policy.rb`
- `app/services/pr_pileup_policies/pile_policy.rb`

### Files to update

- `app/services/scheduled_task_fire.rb` — replace the case statement with `PrPileupPolicies.for(...).new(...).check_pileup`

## Out of scope

- Changing the string values stored in the database
- Adding new pileup policy types
- Moving `has_open_pr?` or `close_prior_open_prs` logic around (those stay where they are)
- Bikeshedding `"pile"` into `"always"` because someone once read a naming guide
