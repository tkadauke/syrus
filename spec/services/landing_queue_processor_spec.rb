require "rails_helper"

RSpec.describe LandingQueueProcessor do
  include ActiveJob::TestHelper

  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }

  def queue_job(issue_number:, approved_at:, parent_job: nil, pr_number: issue_number, repository: self.repository, epic: nil)
    # Start in :implemented so approve! works directly; mirrors the
    # production flow where mark_implemented! happens before approval
    # (post audit, :open → :implemented → :approved is the only
    # legal pre-approval chain).
    Factories.job_record(
      user: user,
      repository: repository,
      issue_number: issue_number,
      pr_number: pr_number,
      parent_job: parent_job,
      epic: epic,
      state: "implemented"
    ).tap do |job|
      job.approve!(via: "github_review")
      job.update!(approved_at: approved_at)
    end
  end

  it "lands an approved stack parent before its child" do
    child = queue_job(issue_number: 2, approved_at: 2.minutes.ago)
    parent = queue_job(issue_number: 1, approved_at: 1.minute.ago)
    child.update!(parent_job: parent)

    workflow = described_class.call

    expect(workflow.job).to eq(parent)
    expect(parent.reload).to be_landing
    expect(child.reload).to be_approved
  end

  it "skips a landing-start blocker while its retry backoff is active" do
    blocked = queue_job(issue_number: 1, approved_at: 2.minutes.ago)
    ready = queue_job(issue_number: 2, approved_at: 1.minute.ago)
    retry_at = 10.minutes.from_now
    blocked.update!(landing_failure_reason: "landing start blocked: workflow admission budget")
    Workflow.create!(
      job: blocked,
      trigger_kind: "auto_merge",
      state: "failed",
      failure_reason: "landing start blocked: workflow admission budget",
      artifacts: {
        "start_blocked_reason" => "landing start blocked: workflow admission budget",
        "start_blocked_next_check_at" => retry_at.iso8601
      }
    )

    workflow = described_class.call

    expect(workflow.job).to eq(ready)
    expect(blocked.reload).to be_approved
    expect(ready.reload).to be_landing
    entry = described_class.entries(Job.where(id: blocked.id)).first
    expect(entry.blocked_reason).to eq(
      { key: "landing_start_blocked_retrying", params: { retry_at: retry_at.iso8601 } }
    )
  end

  it "uses the newest landing-start blocker when deciding whether to skip a retry" do
    blocked = queue_job(issue_number: 1, approved_at: 2.minutes.ago)
    ready = queue_job(issue_number: 2, approved_at: 1.minute.ago)
    retry_at = 10.minutes.from_now
    blocked.update!(landing_failure_reason: "landing start blocked: workflow admission budget")
    Workflow.create!(
      job: blocked,
      trigger_kind: "auto_merge",
      state: "failed",
      failure_reason: "landing start blocked: workflow admission budget",
      artifacts: {
        "start_blocked_reason" => "landing start blocked: workflow admission budget",
        "start_blocked_next_check_at" => 1.minute.ago.iso8601
      }
    )
    Workflow.create!(
      job: blocked,
      trigger_kind: "auto_merge",
      state: "failed",
      failure_reason: "landing start blocked: workflow admission budget",
      artifacts: {
        "start_blocked_reason" => "landing start blocked: workflow admission budget",
        "start_blocked_next_check_at" => retry_at.iso8601
      }
    )

    workflow = described_class.call

    expect(workflow.job).to eq(ready)
    expect(blocked.reload).to be_approved
    entry = described_class.entries(Job.where(id: blocked.id)).first
    expect(entry.blocked_reason).to eq(
      { key: "landing_start_blocked_retrying", params: { retry_at: retry_at.iso8601 } }
    )
  end

  it "shows active admission-blocked landing workflows as retrying without failing the job" do
    blocked = queue_job(issue_number: 1, approved_at: 2.minutes.ago)
    ready = queue_job(issue_number: 2, approved_at: 1.minute.ago)
    retry_at = 10.minutes.from_now
    blocked.start_landing!
    blocked.save!
    Workflow.create!(
      job: blocked,
      trigger_kind: "auto_merge",
      state: "queued",
      artifacts: {
        "start_blocked_reason" => "landing start blocked: workflow admission budget",
        "start_blocked_next_check_at" => retry_at.iso8601
      }
    )

    workflow = described_class.call

    expect(workflow).to be_nil
    expect(blocked.reload).to be_landing
    expect(blocked.landing_failure_reason).to be_nil
    expect(ready.reload).to be_approved
    entry = described_class.entries(Job.where(id: blocked.id)).first
    expect(entry.blocked_reason).to eq(
      { key: "landing_start_blocked_retrying", params: { retry_at: retry_at.iso8601 } }
    )
  end

  it "does not dispatch a second landing workflow for a job that already has one active" do
    job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
    job.start_landing!
    job.save!
    existing = Workflows::AutoMerge.instantiate(job: job)

    expect {
      described_class.new.send(:land, job)
    }.not_to change { Workflow.where(job: job, trigger_kind: "auto_merge").count }

    expect(existing.reload).to be_queued
    expect(job.reload).to be_landing
  end

  it "retries a landing-start blocker after its backoff expires" do
    job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
    job.update!(landing_failure_reason: "landing start blocked: workflow admission budget")
    Workflow.create!(
      job: job,
      trigger_kind: "auto_merge",
      state: "failed",
      failure_reason: "landing start blocked: workflow admission budget",
      artifacts: {
        "start_blocked_reason" => "landing start blocked: workflow admission budget",
        "start_blocked_next_check_at" => 1.minute.ago.iso8601
      }
    )

    workflow = described_class.call

    expect(workflow.job).to eq(job)
    expect(job.reload).to be_landing
    expect(job.landing_failure_reason).to be_nil
  end

  it "places stack parents before children in landing queue positions" do
    child = queue_job(issue_number: 2, approved_at: 2.minutes.ago)
    parent = queue_job(issue_number: 1, approved_at: 1.minute.ago)
    child.update!(parent_job: parent)

    entries = described_class.entries(Job.where(id: [ child.id, parent.id ]))

    expect(entries.map(&:job_id)).to eq([ parent.id, child.id ])
    expect(entries.map(&:position)).to eq([ 1, 2 ])
  end

  it "places explicit Job dependencies before dependents in landing queue positions" do
    dependent = queue_job(issue_number: 2, approved_at: 2.minutes.ago)
    prerequisite = queue_job(issue_number: 1, approved_at: 1.minute.ago)
    JobDependency.create!(job: dependent, depends_on_job: prerequisite, source: "manual")

    entries = described_class.entries(Job.where(id: [ dependent.id, prerequisite.id ]))

    expect(entries.map(&:job_id)).to eq([ prerequisite.id, dependent.id ])
    expect(entries.map(&:position)).to eq([ 1, 2 ])
  end

  it "collects transitive unmerged blockers and dependency edges for each landing unit" do
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    approved = queue_job(issue_number: 3, approved_at: 1.minute.ago, epic: epic)
    blocker = Factories.job_record(user: user, repository: repository, issue_number: 2, state: "implemented", pr_number: 2)
    root_blocker = Factories.job_record(user: user, repository: repository, issue_number: 1, state: "queued", pr_number: 1)
    merged = queue_job(issue_number: 4, approved_at: 2.minutes.ago)
    merged.update!(state: "closed", closure_reason: "pr_merged")
    JobDependency.create!(job: approved, depends_on_job: blocker, source: "manual", created_by_user: user)
    JobDependency.create!(job: blocker, depends_on_job: root_blocker, source: "manual", created_by_user: user)
    JobDependency.create!(job: approved, depends_on_job: merged, source: "manual", created_by_user: user)

    unit = described_class.landing_units(Job.where(id: approved.id)).sole

    expect(unit.key).to eq("epic:#{epic.id}")
    expect(unit.job_ids).to eq([ approved.id ])
    expect(unit.blocker_jobs.map(&:id)).to eq([ root_blocker.id, blocker.id ])
    expect(unit.dependency_edges).to contain_exactly(
      { from_job_id: root_blocker.id, to_job_id: blocker.id },
      { from_job_id: blocker.id, to_job_id: approved.id }
    )
  end

  it "includes unapproved Epic siblings as landing unit blockers" do
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    approved = queue_job(issue_number: 1, approved_at: 1.minute.ago, epic: epic)
    sibling = Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      issue_number: 2,
      state: "implemented",
      pr_number: 2
    )

    unit = described_class.landing_units(Job.where(id: approved.id)).sole

    expect(unit.key).to eq("epic:#{epic.id}")
    expect(unit.job_ids).to eq([ approved.id ])
    expect(unit.blocker_jobs.map(&:id)).to eq([ sibling.id ])
    expect(unit.dependency_edges).to be_empty
  end

  it "groups Epic jobs together in landing queue positions" do
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    epic_child = queue_job(issue_number: 2, approved_at: 3.minutes.ago, epic: epic)
    loose = queue_job(issue_number: 3, approved_at: 2.minutes.ago)
    epic_parent = queue_job(issue_number: 1, approved_at: 1.minute.ago, epic: epic)
    epic_child.update!(parent_job: epic_parent)

    entries = described_class.entries(Job.where(id: [ epic_child.id, loose.id, epic_parent.id ]))

    expect(entries.map(&:job_id)).to eq([ epic_parent.id, epic_child.id, loose.id ])
    expect(entries.map(&:position)).to eq([ 1, 2, 3 ])
  end

  it "keeps cross-unit dependencies ahead of grouped Epic jobs" do
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    epic_ready = queue_job(issue_number: 1, approved_at: 4.minutes.ago, epic: epic)
    prerequisite = queue_job(issue_number: 2, approved_at: 3.minutes.ago)
    epic_dependent = queue_job(issue_number: 3, approved_at: 2.minutes.ago, epic: epic)
    JobDependency.create!(job: epic_dependent, depends_on_job: prerequisite, source: "manual")

    entries = described_class.entries(Job.where(id: [ epic_ready.id, prerequisite.id, epic_dependent.id ]))

    expect(entries.map(&:job_id)).to eq([ prerequisite.id, epic_ready.id, epic_dependent.id ])
    expect(entries.map(&:position)).to eq([ 1, 2, 3 ])
  end

  it "keeps dependency-blocked Jobs approved and lands the next eligible Job" do
    prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 1, state: "queued", pr_number: 1)
    blocked = queue_job(issue_number: 2, approved_at: 2.minutes.ago)
    ready = queue_job(issue_number: 3, approved_at: 1.minute.ago)
    JobDependency.create!(job: blocked, depends_on_job: prerequisite, source: "manual")

    workflow = described_class.call

    expect(workflow.job).to eq(ready)
    expect(blocked.reload).to be_approved
    entry = described_class.entries(Job.where(id: blocked.id)).first
    expect(entry.blocked_reason).to eq({ key: "waiting_to_merge", params: { slug: prerequisite.slug } })
  end

  it "explains when an approved Job is waiting for an Epic dependency" do
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    blocked = queue_job(issue_number: 2, approved_at: 2.minutes.ago)
    JobDependency.create!(job: blocked, depends_on_epic: epic, source: "manual")

    entry = described_class.entries(Job.where(id: blocked.id)).first

    expect(entry.blocked_reason).to eq({ key: "waiting_epic_to_complete", params: { number: epic.number } })
  end

  it "does not process paused users but resumes when unpaused" do
    job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
    user.update!(landing_paused: true)

    expect(described_class.call).to be_nil
    expect(job.reload).to be_approved

    user.update!(landing_paused: false)
    expect(described_class.call.job).to eq(job)
  end

  it "does not transition manually paused approved Jobs into landing" do
    paused = queue_job(issue_number: 1, approved_at: 2.minutes.ago)
    ready = queue_job(issue_number: 2, approved_at: 1.minute.ago)
    paused.pause_manually!(by_user: user)

    workflow = described_class.call

    expect(workflow.job).to eq(ready)
    expect(paused.reload).to be_approved
    entry = described_class.entries(Job.where(id: paused.id)).first
    expect(entry.blocked_reason).to eq({ key: "manual_pause" })
  end

  it "blocks approved Jobs when the repository has landing_paused set and main is broken" do
    job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
    repository.update!(ci_health: "broken", landing_paused: true)

    expect(described_class.call).to be_nil
    expect(job.reload).to be_approved

    entry = described_class.entries(Job.where(id: job.id)).first
    expect(entry.blocked_reason).to eq({ key: "landing_paused_main_broken" })
  end

  it "does not block approved Jobs solely because main health is inconclusive" do
    job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
    repository.update!(ci_health: "not_configured", grader_health: "inconclusive", landing_paused: true)

    workflow = described_class.call

    expect(workflow.job).to eq(job)
    expect(job.reload).to be_landing
  end

  it "does not block approved Jobs solely because main health is unknown" do
    job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
    repository.update!(ci_health: "unknown", grader_health: "unknown", landing_paused: true)

    workflow = described_class.call

    expect(workflow.job).to eq(job)
    expect(job.reload).to be_landing
  end

  it "does not block approved Jobs when repository health enforcement is disabled" do
    job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
    repository.update!(main_branch_health_enabled: false, ci_health: "broken", landing_paused: true)

    workflow = described_class.call

    expect(workflow.job).to eq(job)
    expect(job.reload).to be_landing
  end

  it "lets a fix-main direct Job land while repository landing is paused for broken main" do
    fix_job = Factories.job_record(
      user: user,
      repository: repository,
      kind: "direct",
      issue_number: nil,
      issue_title: MainHealthChangedService::FIX_MAIN_TITLE,
      issue_body: "Restore main.",
      pr_number: 123,
      state: "implemented"
    )
    fix_job.approve!(via: "operator")
    fix_job.update!(approved_at: 1.minute.ago)
    repository.update!(ci_health: "broken", landing_paused: true)

    workflow = described_class.call

    expect(workflow).to be_present
    expect(workflow.job).to eq(fix_job)
    expect(workflow.trigger_kind).to eq("auto_merge")
    expect(fix_job.reload).to be_landing
  end

  it "resumes landing for a repository once repository.landing_paused is cleared" do
    job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
    repository.update!(ci_health: "broken", landing_paused: true)

    expect(described_class.call).to be_nil

    repository.update!(landing_paused: false)
    expect(described_class.call.job).to eq(job)
  end

  it "blocks approved Jobs after a no-op rebase while GitHub still reports unmergeable" do
    job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
    job.update!(pr_mergeable: false)
    Workflows::Rebase.instantiate(job: job).update!(
      state: "succeeded",
      artifacts: {
        "auto_rebase_result" => {
          "reason" => "rebased",
          "changed" => false,
          "post_sha" => "abc",
          "base_sha" => "base"
        }
      }
    )

    expect(described_class.call).to be_nil
    expect(job.reload).to be_approved
    entry = described_class.entries(Job.where(id: job.id)).first
    expect(entry.blocked_reason).to eq({ key: "waiting_github_mergeability_noop" })
  end

  it "briefly blocks approved Jobs after an unknown GitHub mergeability preflight passed locally" do
    job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
    job.update!(
      github_mergeable_state: "unknown",
      mergeability_checked_at: Time.current,
      local_mergeable: true,
      local_mergeable_state: "clean"
    )

    expect(described_class.call).to be_nil
    expect(job.reload).to be_approved
    entry = described_class.entries(Job.where(id: job.id)).first
    expect(entry.blocked_reason).to eq({ key: "waiting_github_mergeability" })
  end

  it "retries approved Jobs after the GitHub mergeability cooldown expires" do
    job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
    job.update!(
      github_mergeable_state: "unknown",
      mergeability_checked_at: described_class::MERGEABILITY_RECHECK_DELAY.ago - 1.second,
      local_mergeable: true,
      local_mergeable_state: "clean"
    )

    workflow = described_class.call

    expect(workflow.job).to eq(job)
    expect(job.reload).to be_landing
  end

  it "blocks approved Jobs whose rebase cap is exhausted while GitHub still reports unmergeable" do
    job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
    job.update!(pr_mergeable: false, landing_failure_reason: "auto_merge: dirty and rebase cap reached")
    RebaseAttemptGuard::ATTEMPT_CAP.times do
      Workflows::Rebase.instantiate(job: job).update!(state: "failed")
    end

    expect {
      expect(described_class.call).to be_nil
    }.not_to change { job.workflows.where(trigger_kind: "auto_merge").count }

    expect(job.reload).to be_approved
    entry = described_class.entries(Job.where(id: job.id)).first
    expect(entry.blocked_reason).to eq({ key: "rebase_cap_reached" })
  end

  it "clears a stale landing failure reason when a Job starts landing again" do
    job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
    job.update!(landing_failure_reason: "old landing failure")

    workflow = described_class.call

    expect(workflow.job).to eq(job)
    expect(job.reload).to be_landing
    expect(job.landing_failure_reason).to be_nil
  end

  it "holds approved epic jobs until every open sibling is approved" do
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    approved = queue_job(issue_number: 1, approved_at: 1.minute.ago, epic: epic)
    Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      issue_number: 2,
      pr_number: 2,
      state: "implemented"
    )

    expect(described_class.call).to be_nil
    expect(approved.reload).to be_approved
    entry = described_class.entries(Job.where(id: approved.id)).first
    expect(entry.blocked_reason).to eq({ key: "waiting_epic_siblings" })
    expect(entry.waiting_for_jobs.map(&:issue_number)).to eq([ 2 ])
  end

  it "starts queued epic siblings once their same-epic dependencies are approved" do
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    first = queue_job(issue_number: 1, approved_at: 3.minutes.ago, epic: epic)
    second = queue_job(issue_number: 2, approved_at: 2.minutes.ago, epic: epic)
    queued = Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      issue_number: 3,
      state: "queued"
    )
    workflow = Workflows::Initial.instantiate(job: queued)
    first_step = workflow.first_step
    Factories.legacy_job_dependency(job: queued, depends_on_job: first)
    Factories.legacy_job_dependency(job: queued, depends_on_job: second)

    expect(first_step.runs.count).to eq(0)

    expect(described_class.call).to be_nil
    expect(first_step.runs.reload.count).to eq(1)
    expect(first.reload).to be_approved
    expect(second.reload).to be_approved
  end

  it "ignores closed epic siblings when checking whether every open sibling is approved" do
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    approved = queue_job(issue_number: 1, approved_at: 1.minute.ago, epic: epic)
    Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      issue_number: 2,
      pr_number: 2,
      state: "closed",
      closure_reason: "pr_merged"
    )

    workflow = described_class.call

    expect(workflow.job).to eq(approved)
    expect(approved.reload).to be_landing
  end

  it "lands approved Jobs in different repositories in the same tick" do
    other_repository = Factories.repository(user: user, auto_merge_enabled: true, name: "other")
    first = queue_job(issue_number: 1, approved_at: 2.minutes.ago)
    second = queue_job(issue_number: 2, approved_at: 1.minute.ago, repository: other_repository)

    workflow = described_class.call

    expect(workflow.job).to eq(first)
    expect(first.reload).to be_landing
    expect(second.reload).to be_landing
    expect(Workflow.where(trigger_kind: "auto_merge").pluck(:job_id)).to contain_exactly(first.id, second.id)
  end

  it "lands only the oldest approved Job per repository in the same tick" do
    older = queue_job(issue_number: 1, approved_at: 2.minutes.ago)
    newer = queue_job(issue_number: 2, approved_at: 1.minute.ago)

    workflow = described_class.call

    expect(workflow.job).to eq(older)
    expect(older.reload).to be_landing
    expect(newer.reload).to be_approved
  end

  it "lands an approved Job from another repository while a repository is already landing" do
    other_repository = Factories.repository(user: user, auto_merge_enabled: true, name: "other")
    landing = queue_job(issue_number: 1, approved_at: 2.minutes.ago)
    ready = queue_job(issue_number: 2, approved_at: 1.minute.ago, repository: other_repository)
    landing.start_landing!
    landing.save!

    workflow = described_class.call

    expect(workflow.job).to eq(ready)
    expect(ready.reload).to be_landing
  end

  it "skips an approved Job whose repository is already landing" do
    landing = queue_job(issue_number: 1, approved_at: 2.minutes.ago)
    ready = queue_job(issue_number: 2, approved_at: 1.minute.ago)
    landing.start_landing!
    landing.save!

    expect(described_class.call).to be_nil
    expect(ready.reload).to be_approved
  end

  describe "priority ordering" do
    it "lands an urgent approved Job ahead of older medium and low Jobs" do
      low = queue_job(issue_number: 1, approved_at: 10.minutes.ago).tap { |j| j.update!(priority: "low") }
      medium = queue_job(issue_number: 2, approved_at: 5.minutes.ago)
      urgent = queue_job(issue_number: 3, approved_at: 1.minute.ago).tap { |j| j.update!(priority: "urgent") }

      workflow = described_class.call

      expect(workflow.job).to eq(urgent)
      expect(urgent.reload).to be_landing
      expect(medium.reload).to be_approved
      expect(low.reload).to be_approved
    end

    it "orders entries and cached positions by priority before FIFO approval time" do
      low = queue_job(issue_number: 1, approved_at: 10.minutes.ago).tap { |j| j.update!(priority: "low") }
      high = queue_job(issue_number: 2, approved_at: 1.minute.ago).tap { |j| j.update!(priority: "high") }
      medium = queue_job(issue_number: 3, approved_at: 5.minutes.ago)
      urgent = queue_job(issue_number: 4, approved_at: 30.seconds.ago).tap { |j| j.update!(priority: "urgent") }

      entries = described_class.refresh_snapshot!(Job.where(id: [ low.id, high.id, medium.id, urgent.id ]))

      expect(entries.map(&:job_id)).to eq([ urgent.id, high.id, medium.id, low.id ])
      expect(urgent.reload.landing_queue_entry_position).to eq(1)
      expect(high.reload.landing_queue_entry_position).to eq(2)
      expect(medium.reload.landing_queue_entry_position).to eq(3)
      expect(low.reload.landing_queue_entry_position).to eq(4)
    end

    it "keeps dependency prerequisites ahead of urgent dependents" do
      dependent = queue_job(issue_number: 2, approved_at: 1.minute.ago).tap { |j| j.update!(priority: "urgent") }
      prerequisite = queue_job(issue_number: 1, approved_at: 10.minutes.ago)
      JobDependency.create!(job: dependent, depends_on_job: prerequisite, source: "manual")

      entries = described_class.entries(Job.where(id: [ dependent.id, prerequisite.id ]))
      workflow = described_class.call

      expect(entries.map(&:job_id)).to eq([ prerequisite.id, dependent.id ])
      expect(workflow.job).to eq(prerequisite)
      expect(prerequisite.reload).to be_landing
      expect(dependent.reload).to be_approved
    end

    it "uses priority-aware order for rebase prefetch depth" do
      low = queue_job(issue_number: 1, approved_at: 10.minutes.ago).tap { |j| j.update!(priority: "low") }
      queue_job(issue_number: 2, approved_at: 5.minutes.ago)
      urgent = queue_job(issue_number: 3, approved_at: 1.minute.ago).tap { |j| j.update!(priority: "urgent") }

      expect(described_class.rebase_prefetch_candidate?(urgent, depth: 1)).to be(true)
      expect(described_class.rebase_prefetch_candidate?(low, depth: 1)).to be(false)
    end
  end

  # Regression: an approved Job on a repo without auto_merge_enabled
  # used to be picked up by the queue, transitioned to :landing,
  # then immediately failed at AutoMergeGate ("repository has not
  # enabled auto-merge") — which fail_landing'd and wiped the
  # approved_at. blockage_for now catches this so the Job stays
  # approved with a clear blocked_reason until the repo is configured.
  it "blocks approved Jobs whose repository does not have auto-merge enabled" do
    disabled_repo = Factories.repository(user: user, auto_merge_enabled: false)
    job = Factories.job_record(user: user, repository: disabled_repo, issue_number: 1,
                                pr_number: 1, state: "implemented").tap do |j|
      j.approve!(via: "github_review")
    end

    expect(described_class.call).to be_nil
    expect(job.reload).to be_approved
    entry = described_class.entries(Job.where(id: job.id)).first
    expect(entry.blocked_reason).to eq({ key: "auto_merge_not_enabled" })
  end

  it "uses a matching landing blocker override exactly once" do
    blocked = queue_job(issue_number: 1, approved_at: 2.minutes.ago)
    ready = queue_job(issue_number: 2, approved_at: 1.minute.ago)
    user.update!(landing_paused: true)
    blocked.update!(
      landing_blocker_override_key: "landing_paused",
      landing_blocker_override_reason: "operator verified pause metadata is stale",
      landing_blocker_override_requested_at: Time.current,
      landing_blocker_override_requested_by_user_id: user.id
    )

    workflow = described_class.call

    expect(workflow.job).to eq(blocked)
    expect(blocked.reload).to be_landing
    expect(blocked.landing_blocker_override_used_at).to be_present
    expect(ready.reload).to be_approved
  end

  it "does not bypass non-overridable PR check blockers" do
    job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
    job.update!(
      pr_checks_sha: "abc123",
      pr_checks_state: "failing",
      pr_checks_checked_at: Time.current,
      landing_blocker_override_key: "pr_checks_failing",
      landing_blocker_override_reason: "incorrect check cache",
      landing_blocker_override_requested_at: Time.current,
      landing_blocker_override_requested_by_user_id: user.id
    )

    expect(described_class.call).to be_nil
    expect(job.reload).to be_approved
    expect(job.landing_blocker_override_used_at).to be_nil
  end

  it "classifies every Epic child as waiting for the merge train" do
    AppSetting.current.update!(merge_train_enabled: true)
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    child = queue_job(issue_number: 1, approved_at: 1.minute.ago, epic: epic)

    entry = described_class.entries(Job.where(id: child.id)).first

    expect(entry.blocked_reason).to eq({ key: "waiting_epic_merge_train" })
  end

  describe "CI cleanliness gate" do
    it "blocks a job with an active ci_failure workflow with a specific message" do
      job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
      Workflows::CiFailure.instantiate(job: job).update!(state: "running")

      expect(described_class.call).to be_nil
      expect(job.reload).to be_approved
      entry = described_class.entries(Job.where(id: job.id)).first
      expect(entry.blocked_reason).to eq({ key: "ci_failure_in_progress", params: { slug: job.slug } })
    end

    it "blocks a job whose PR checks are cached as failing" do
      job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
      job.update_columns(pr_checks_sha: "abc123", pr_checks_state: "failing", pr_checks_checked_at: Time.current)

      expect(described_class.call).to be_nil
      expect(job.reload).to be_approved
      entry = described_class.entries(Job.where(id: job.id)).first
      expect(entry.blocked_reason).to eq({ key: "pr_checks_failing", params: { slug: job.slug } })
    end

    it "surfaces no-effective CI repairs instead of the generic failing checks reason" do
      job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
      job.update_columns(
        pr_checks_sha: "abc123",
        pr_checks_state: "failing",
        pr_checks_checked_at: Time.current,
        landing_failure_reason: "#{PollPullRequestJob::NO_EFFECTIVE_CI_REPAIR_REASON} on abc123"
      )

      expect(described_class.call).to be_nil
      expect(job.reload).to be_approved
      entry = described_class.entries(Job.where(id: job.id)).first
      expect(entry.blocked_reason).to eq({ key: "ci_repair_no_effective_change", params: { slug: job.slug } })
    end

    it "blocks a job whose PR checks are cached as pending" do
      job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
      job.update_columns(pr_checks_sha: "abc123", pr_checks_state: "pending", pr_checks_checked_at: Time.current)

      expect(described_class.call).to be_nil
      expect(job.reload).to be_approved
      entry = described_class.entries(Job.where(id: job.id)).first
      expect(entry.blocked_reason).to eq({ key: "pr_checks_pending", params: { slug: job.slug } })
    end

    it "allows landing when PR checks are cached as passing" do
      job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
      job.update_columns(pr_checks_sha: "abc123", pr_checks_state: "passing", pr_checks_checked_at: Time.current)

      workflow = described_class.call

      expect(workflow.job).to eq(job)
      expect(job.reload).to be_landing
    end

    it "allows landing when pr_checks_state is nil (never polled)" do
      job = queue_job(issue_number: 1, approved_at: 1.minute.ago)

      workflow = described_class.call

      expect(workflow.job).to eq(job)
      expect(job.reload).to be_landing
    end

    it "blocks an Epic member when a sibling has an active ci_failure workflow" do
      epic = Factories.epic(user: user, repository: repository, state: "in_progress")
      ready = queue_job(issue_number: 1, approved_at: 2.minutes.ago, epic: epic)
      sibling = queue_job(issue_number: 2, approved_at: 1.minute.ago, epic: epic)
      Workflows::CiFailure.instantiate(job: sibling).update!(state: "running")

      expect(described_class.call).to be_nil
      expect(ready.reload).to be_approved
      entry = described_class.entries(Job.where(id: ready.id)).first
      expect(entry.blocked_reason).to eq({ key: "ci_failure_in_progress", params: { slug: sibling.slug } })
      expect(entry.waiting_for_jobs.map(&:id)).to eq([sibling.id])
    end

    it "blocks an Epic member when a sibling's PR checks are failing" do
      epic = Factories.epic(user: user, repository: repository, state: "in_progress")
      ready = queue_job(issue_number: 1, approved_at: 2.minutes.ago, epic: epic)
      sibling = queue_job(issue_number: 2, approved_at: 1.minute.ago, epic: epic)
      sibling.update_columns(pr_checks_sha: "abc123", pr_checks_state: "failing", pr_checks_checked_at: Time.current)

      expect(described_class.call).to be_nil
      expect(ready.reload).to be_approved
      entry = described_class.entries(Job.where(id: ready.id)).first
      expect(entry.blocked_reason).to eq({ key: "pr_checks_failing", params: { slug: sibling.slug } })
      expect(entry.waiting_for_jobs.map(&:id)).to eq([sibling.id])
    end

    it "blocks an Epic member when a sibling's PR checks are pending" do
      epic = Factories.epic(user: user, repository: repository, state: "in_progress")
      ready = queue_job(issue_number: 1, approved_at: 2.minutes.ago, epic: epic)
      sibling = queue_job(issue_number: 2, approved_at: 1.minute.ago, epic: epic)
      sibling.update_columns(pr_checks_sha: "def456", pr_checks_state: "pending", pr_checks_checked_at: Time.current)

      expect(described_class.call).to be_nil
      expect(ready.reload).to be_approved
      entry = described_class.entries(Job.where(id: ready.id)).first
      expect(entry.blocked_reason).to eq({ key: "pr_checks_pending", params: { slug: sibling.slug } })
    end

    it "prefers failing over pending when an Epic has both kinds of sibling issues" do
      epic = Factories.epic(user: user, repository: repository, state: "in_progress")
      ready = queue_job(issue_number: 1, approved_at: 3.minutes.ago, epic: epic)
      failing_sib = queue_job(issue_number: 2, approved_at: 2.minutes.ago, epic: epic)
      pending_sib = queue_job(issue_number: 3, approved_at: 1.minute.ago, epic: epic)
      failing_sib.update_columns(pr_checks_sha: "abc", pr_checks_state: "failing", pr_checks_checked_at: Time.current)
      pending_sib.update_columns(pr_checks_sha: "def", pr_checks_state: "pending", pr_checks_checked_at: Time.current)

      entry = described_class.entries(Job.where(id: ready.id)).first
      expect(entry.blocked_reason).to eq({ key: "pr_checks_failing", params: { slug: failing_sib.slug } })
    end

    it "does not block an Epic member for a sibling that is closed" do
      epic = Factories.epic(user: user, repository: repository, state: "in_progress")
      ready = queue_job(issue_number: 1, approved_at: 1.minute.ago, epic: epic)
      closed = Factories.job_record(
        user: user, repository: repository, epic: epic,
        issue_number: 2, pr_number: 2,
        state: "closed", closure_reason: "pr_merged"
      )
      closed.update_columns(pr_checks_sha: "abc", pr_checks_state: "failing", pr_checks_checked_at: Time.current)

      workflow = described_class.call

      expect(workflow.job).to eq(ready)
      expect(ready.reload).to be_landing
    end
  end

  describe ".try_land!" do
    it "enqueues an immediate landing-queue pass when no specific Job is given" do
      expect {
        described_class.try_land!
      }.to have_enqueued_job(LandingQueueProcessorJob)
    end

    it "dispatches an AutoMerge workflow for a specific approved Job" do
      job = queue_job(issue_number: 1, approved_at: 1.minute.ago)

      workflow = described_class.try_land!(job)

      expect(workflow).to be_present
      expect(workflow.trigger_kind).to eq("auto_merge")
      expect(job.reload).to be_landing
    end

    it "retries a transient landing lock conflict for a specific Job" do
      job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
      processor = instance_double(described_class)
      calls = 0
      allow(described_class).to receive(:new).and_return(processor)
      allow(processor).to receive(:try_land!).with(job) do
        calls += 1
        raise ActiveRecord::Deadlocked, "deadlock" if calls == 1

        :landed
      end

      expect(described_class.try_land!(job)).to eq(:landed)
      expect(calls).to eq(2)
    end

    it "queues a landing processor retry and requests reconciliation when landing lock conflicts persist" do
      job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
      processor = instance_double(described_class)
      allow(described_class).to receive(:new).and_return(processor)
      allow(processor).to receive(:try_land!).with(job).and_raise(ActiveRecord::Deadlocked, "deadlock")

      expect {
        expect(described_class.try_land!(job)).to be_nil
      }.to have_enqueued_job(LandingQueueProcessorJob)
        .and have_enqueued_job(WorkEngine::ReconcileJob).with(
          source: "LandingQueueProcessor.try_land_lock_conflict",
          job_id: job.id,
          workflow_id: nil,
          run_id: nil
        )
    end

    it "no-ops when the Job is not approved" do
      job = Factories.job_record(user: user, repository: repository, issue_number: 1,
                                  pr_number: 1, state: "implemented")

      expect(described_class.try_land!(job)).to be_nil
      expect(job.reload).to be_implemented
    end

    it "no-ops when a blocker (active workflow) is present" do
      job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
      Workflows::Rebase.instantiate(job: job).update!(state: "running")

      expect(described_class.try_land!(job)).to be_nil
      expect(job.reload).to be_approved
    end

    it "no-ops when another Job in the same repository is already landing" do
      already_landing = queue_job(issue_number: 1, approved_at: 2.minutes.ago)
      already_landing.start_landing!
      already_landing.save!

      target = queue_job(issue_number: 2, approved_at: 1.minute.ago)

      expect(described_class.try_land!(target)).to be_nil
      expect(target.reload).to be_approved
    end

    it "no-ops when the target Job already has an active landing workflow" do
      job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
      job.start_landing!
      job.save!
      Workflows::AutoMerge.instantiate(job: job)
      job.update!(state: "approved")

      expect {
        expect(described_class.try_land!(job)).to be_nil
      }.not_to change { Workflow.where(job: job, trigger_kind: "auto_merge").count }

      expect(job.reload).to be_approved
    end

    it "dispatches when another repository is already landing" do
      other_repository = Factories.repository(user: user, auto_merge_enabled: true, name: "other")
      already_landing = queue_job(issue_number: 1, approved_at: 2.minutes.ago)
      already_landing.start_landing!
      already_landing.save!

      target = queue_job(issue_number: 2, approved_at: 1.minute.ago, repository: other_repository)

      workflow = described_class.try_land!(target)

      expect(workflow.job).to eq(target)
      expect(target.reload).to be_landing
    end
  end

  describe "urgent job gate" do
    it "does not block a non-urgent job when no urgent jobs are open" do
      job = queue_job(issue_number: 1, approved_at: 1.minute.ago)

      entry = described_class.entries(Job.where(id: job.id)).first

      expect(entry.blocked_reason).to be_blank
    end

    it "blocks a non-urgent job when an urgent job is open in the same repository" do
      queue_job(issue_number: 1, approved_at: 5.minutes.ago).tap { |j| j.update!(priority: "urgent") }
      non_urgent = queue_job(issue_number: 2, approved_at: 4.minutes.ago)

      entry = described_class.entries(Job.where(id: non_urgent.id)).first

      expect(entry.blocked_reason).to eq({ key: "urgent_job_active" })
    end

    it "does not block a non-urgent job when urgent jobs are terminal" do
      Factories.job_record(
        user: user,
        repository: repository,
        issue_number: 1,
        priority: "urgent",
        state: "no_change_needed"
      )
      Factories.job_record(
        user: user,
        repository: repository,
        issue_number: 2,
        priority: "urgent",
        state: "closed"
      )
      non_urgent = queue_job(issue_number: 3, approved_at: 4.minutes.ago)

      entry = described_class.entries(Job.where(id: non_urgent.id)).first

      expect(entry.blocked_reason).to be_blank
    end

    it "does not block an urgent job even when another urgent job is open" do
      urgent = queue_job(issue_number: 1, approved_at: 1.minute.ago).tap { |j| j.update!(priority: "urgent") }
      queue_job(issue_number: 2, approved_at: 2.minutes.ago).tap { |j| j.update!(priority: "urgent") }

      entry = described_class.entries(Job.where(id: urgent.id)).first

      expect(entry.blocked_reason).to be_blank
    end
  end

  describe "external_pr jobs" do
    def queue_external_pr_job(external_pr_number:, approved_at:, repo: repository)
      # external_pr Jobs must be created in :implemented state (validated on create).
      # Factories.job_record always overrides state to "closed" then update_columns,
      # so we use Job.create! directly for external_pr kind.
      Job.create!(
        user: user,
        owner_user: user,
        repository: repo,
        kind: "external_pr",
        issue_number: nil,
        external_pr_number: external_pr_number,
        state: "implemented"
      ).tap do |job|
        job.approve!(via: "operator")
        job.update!(approved_at: approved_at)
      end
    end

    it "does not block an approved external_pr Job that has an external_pr_number" do
      job = queue_external_pr_job(external_pr_number: 7, approved_at: 1.minute.ago)

      entry = described_class.entries(Job.where(id: job.id)).first

      expect(entry.blocked_reason).to be_blank
    end

    it "dispatches ExternalPrMerge (not AutoMerge) for an approved external_pr Job" do
      job = queue_external_pr_job(external_pr_number: 7, approved_at: 1.minute.ago)

      workflow = described_class.call

      expect(workflow).to be_present
      expect(workflow.trigger_kind).to eq("external_pr_merge")
      expect(workflow.job).to eq(job)
      expect(job.reload).to be_landing
    end

    it "dispatches ExternalPrMerge via try_land! for a specific external_pr Job" do
      job = queue_external_pr_job(external_pr_number: 7, approved_at: 1.minute.ago)

      workflow = described_class.try_land!(job)

      expect(workflow).to be_present
      expect(workflow.trigger_kind).to eq("external_pr_merge")
      expect(job.reload).to be_landing
    end

    it "lands both an external_pr Job and a regular Job in different repositories in the same tick" do
      other_repository = Factories.repository(user: user, auto_merge_enabled: true, name: "other")
      regular = queue_job(issue_number: 1, approved_at: 2.minutes.ago)
      external = queue_external_pr_job(external_pr_number: 7, approved_at: 1.minute.ago, repo: other_repository)

      described_class.call

      expect(regular.reload).to be_landing
      expect(external.reload).to be_landing
      expect(Workflow.where(trigger_kind: "auto_merge").pluck(:job_id)).to eq([ regular.id ])
      expect(Workflow.where(trigger_kind: "external_pr_merge").pluck(:job_id)).to eq([ external.id ])
    end
  end

end
