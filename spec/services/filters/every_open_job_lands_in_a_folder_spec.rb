require "rails_helper"

# The dashboard's folders are subtractive: several of them exclude a Job on
# the assumption that a different folder claims it instead. "In progress"
# subtracts every blocked WorkUnit because nothing is progressing; "Landing
# queue" subtracts a Job whose upstream reviewer asked for changes because it
# is no longer queued to land. Both are correct in isolation, and both leave a
# Job in no folder at all when the folder that was supposed to pick it up
# does not exist.
#
# That has happened twice in production, by different routes and weeks apart:
# a cron Job blocked on main-branch health sat `running` for thirteen hours,
# and an approved external-PR Job sat with `needs_attention` true for six
# weeks. Neither appeared anywhere on the dashboard; both read as healthy
# while nothing worked on them.
#
# So the invariant is asserted directly rather than trusted: every shape an
# open Job can take must be claimed by at least one folder the operator
# actually sees. `:on_demand` folders do not count -- "All jobs", "Stale" and
# "Merged this week" live behind the "More" disclosure, and "All jobs" matches
# everything by construction, so counting them would make this spec vacuous.
RSpec.describe "every open Job lands in a visible smart folder" do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def visible_folders
    SmartFolder::JOB_BUILTINS.reject { |folder| folder[:visibility] == :on_demand }
  end

  def folders_claiming(job)
    visible_folders.filter_map do |folder|
      matched = Filters::Compiler.call(
        Filters::Ast.parse(folder[:filter]),
        scope: Job.where(id: job.id),
        user: user
      )
      folder[:name] if matched.exists?
    end
  end

  def block_work_unit!(job, reason:, kind: "initial")
    workflow = Workflow.create!(job: job, trigger_kind: kind, state: "running", user: job.user)
    intent = WorkIntent.create!(kind: kind, state: "requested", repository: job.repository,
                                scope_type: "job", scope_id: job.id)
    unit = WorkUnit.create!(work_intent: intent, kind: kind, state: "blocked",
                            repository: job.repository, scope_type: "job", scope_id: job.id,
                            workflow: workflow, blocked_reason: reason, blocked_at: Time.current)
    unit.work_unit_members.create!(job: job, role: "primary")
    unit
  end

  # Each case is a shape an open Job genuinely reaches in production.
  {
    "queued" => ->(job) { job },
    "running with work actually executing" => lambda { |job|
      job.update!(state: "running")
      job
    },
    "triaging" => ->(job) { job.update!(state: "triaging"); job },
    "backlog" => ->(job) { job.update!(state: "backlog"); job },
    "implemented, awaiting approval" => ->(job) { job.update!(state: "implemented"); job },
    "approved and queued to land" => ->(job) { job.update!(state: "approved"); job },
    "landing" => ->(job) { job.update!(state: "landing"); job },
    "failed" => ->(job) { job.update!(state: "failed"); job },
    "manually paused" => lambda { |job|
      job.update!(state: "running", manual_paused: true)
      job
    },
    # The thirteen-hour cron Job: mid-chain, nothing executing, no failure.
    "running but its WorkUnit is blocked mid-chain" => lambda { |job|
      job.update!(state: "running")
      job
    },
    # The six-week external-PR Job: dropped by Landing queue on purpose.
    "approved with upstream changes requested" => lambda { |job|
      job.update!(state: "approved",
                  needs_attention: true,
                  needs_attention_reason: Job::REQUESTED_CHANGES_ATTENTION_REASON,
                  needs_attention_since: 6.weeks.ago)
      job
    }
  }.each_with_index do |(shape, setup), index|
    it "claims a Job that is #{shape}" do
      job = Factories.job_record(repository: repo, user: user, issue_number: 500 + index)
      job = setup.call(job)
      block_work_unit!(job, reason: "main_branch_health") if shape.include?("WorkUnit is blocked")

      claimed = folders_claiming(job.reload)

      expect(claimed).not_to be_empty,
        "a Job that is #{shape} appears in no visible smart folder, so the operator " \
        "has no way to find it. Give it a folder rather than relying on another one " \
        "to pick it up."
    end
  end
end
