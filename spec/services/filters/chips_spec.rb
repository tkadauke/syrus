require "rails_helper"

# Per-chip smoke tests. The Compiler is exercised via the public
# Filters::Compiler.call entry — these specs lean on it rather than
# instantiating chip classes directly so the AST round-trip is part
# of the coverage.
RSpec.describe "Filters::Chips" do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def run(field:, op:, value:, scope: Job.where(user: user))
    # Scope to the test's user so leakage from prior specs in the same
    # suite (or before(:context) seeds for unrelated users) doesn't
    # pollute results. The Repository chip still sees multiple repos
    # within the user's scope.
    Filters::Compiler.call(
      Filters::Ast.parse("field" => field, "op" => op, "value" => value),
      scope: scope,
      user: user
    )
  end

  def create_blocked_work_unit_for(job, kind: "initial", blocked_reason: "admission_control")
    workflow = Workflow.create!(job: job, trigger_kind: kind, state: "running")
    intent = WorkIntent.create!(
      kind: kind,
      state: "requested",
      repository: job.repository,
      scope_type: "job",
      scope_id: job.id
    )
    unit = WorkUnit.create!(
      work_intent: intent,
      kind: kind,
      state: "blocked",
      repository: job.repository,
      scope_type: "job",
      scope_id: job.id,
      workflow: workflow,
      blocked_reason: blocked_reason
    )
    unit.work_unit_members.create!(job: job, role: "primary")
    unit
  end

  def create_running_work_unit_for(primary_job, member_jobs: [ primary_job ], kind: "initial")
    workflow = Workflow.create!(job: primary_job, trigger_kind: kind, state: "running")
    intent = WorkIntent.create!(
      kind: kind,
      state: "requested",
      repository: primary_job.repository,
      scope_type: "job",
      scope_id: primary_job.id
    )
    unit = WorkUnit.create!(
      work_intent: intent,
      kind: kind,
      state: "running",
      repository: primary_job.repository,
      scope_type: "job",
      scope_id: primary_job.id,
      workflow: workflow
    )
    member_jobs.each_with_index do |job, index|
      unit.work_unit_members.create!(job: job, role: index.zero? ? "primary" : "member")
    end
    unit
  end

  def create_queued_work_unit_for(primary_job, member_jobs: [ primary_job ], kind: "initial")
    workflow = Workflow.create!(job: primary_job, trigger_kind: kind, state: "queued")
    intent = WorkIntent.create!(
      kind: kind,
      state: "requested",
      repository: primary_job.repository,
      scope_type: "job",
      scope_id: primary_job.id
    )
    unit = WorkUnit.create!(
      work_intent: intent,
      kind: kind,
      state: "queued",
      repository: primary_job.repository,
      scope_type: "job",
      scope_id: primary_job.id,
      workflow: workflow
    )
    member_jobs.each_with_index do |job, index|
      unit.work_unit_members.create!(job: job, role: index.zero? ? "primary" : "member")
    end
    unit
  end

  def set_feature(slug, enabled)
    Feature.find_or_create_by!(slug: slug) do |feature|
      feature.category = "Operations"
      feature.name = slug.humanize
    end.update!(enabled: enabled)
    Feature.clear_enabled_cache!(slug)
  end

  describe "state" do
    it "filters by exact state" do
      queued_job = Factories.job(repository: repo, issue_number: 1)
      closed_job = Factories.job(repository: repo, issue_number: 2)
      closed_job.close!; closed_job.save!

      expect(run(field: "state", op: "is", value: queued_job.state)).to contain_exactly(queued_job)
    end

    it "supports is_one_of for multi-value matches" do
      queued_job = Factories.job(repository: repo, issue_number: 1)
      closed_job = Factories.job(repository: repo, issue_number: 2)
      closed_job.close!; closed_job.save!

      expect(run(field: "state", op: "is_one_of", value: [ queued_job.state, "closed" ])).to contain_exactly(queued_job, closed_job)
    end
  end

  describe "repository_id" do
    it "filters to one repository" do
      api = Factories.repository(user: user, owner: "acme", name: "api")
      mine = Factories.job(repository: repo, issue_number: 1)
      Factories.job(repository: api, issue_number: 2)

      expect(run(field: "repository_id", op: "is", value: repo.id)).to contain_exactly(mine)
    end
  end

  describe "pr_present" do
    it "matches jobs with a PR when op is is_true" do
      with_pr = Factories.job(repository: repo, issue_number: 1, pr_number: 42)
      Factories.job(repository: repo, issue_number: 2)

      expect(run(field: "pr_present", op: "is_true", value: nil)).to contain_exactly(with_pr)
    end

    it "matches jobs without a PR when op is is_false" do
      Factories.job(repository: repo, issue_number: 1, pr_number: 42)
      without = Factories.job(repository: repo, issue_number: 2)

      expect(run(field: "pr_present", op: "is_false", value: nil)).to contain_exactly(without)
    end
  end

  describe "age" do
    it "filters by created_at within the named window" do
      fresh = Factories.job(repository: repo, issue_number: 1)
      old = Factories.job(repository: repo, issue_number: 2)
      old.update!(created_at: 30.days.ago)

      expect(run(field: "age", op: "is", value: "1d")).to contain_exactly(fresh)
    end
  end

  describe "has_active_run" do
    it "matches only jobs with active Runs, not pending WorkUnit ownership" do
      owner = Factories.job_record(repository: repo, issue_number: 10, state: "running")
      member = Factories.job_record(repository: repo, issue_number: 11, state: "running")
      inactive = Factories.job_record(repository: repo, issue_number: 12, state: "implemented")
      workflow = WorkUnits::Launcher.instantiate(kind: "merge_train", job: owner)
      workflow.update!(state: "running")
      workflow.work_unit.work_unit_members.create!(job: member, role: "member")

      expect(run(field: "has_active_run", op: "is_true", value: nil)).to be_empty
      expect(run(field: "has_active_run", op: "is_false", value: nil)).to include(owner, member, inactive)

      step = workflow.steps.create!(kind: "merge_train_assemble", position: 1, state: "running")
      Run.create!(job: owner, step: step, state: "running", trigger_kind: workflow.trigger_kind, agent_provider: owner.agent_provider)

      expect(run(field: "has_active_run", op: "is_true", value: nil)).to contain_exactly(owner)
    end
  end

  describe "tags" do
    let(:bug) { Factories.tag(user: user, name: "bug") }
    let(:epic) { Factories.tag(user: user, name: "epic") }

    it "contains_any returns jobs with at least one of the tags" do
      tagged = Factories.job(repository: repo, issue_number: 1)
      tagged.tags << bug
      Factories.job(repository: repo, issue_number: 2)

      expect(run(field: "tags", op: "contains_any", value: [ bug.id ])).to contain_exactly(tagged)
    end

    it "contains_all only matches jobs with every listed tag" do
      both = Factories.job(repository: repo, issue_number: 1)
      both.tags << bug
      both.tags << epic
      one = Factories.job(repository: repo, issue_number: 2)
      one.tags << bug

      expect(run(field: "tags", op: "contains_all", value: [ bug.id, epic.id ])).to contain_exactly(both)
    end

    it "contains_none excludes jobs that have any of the listed tags" do
      tagged = Factories.job(repository: repo, issue_number: 1)
      tagged.tags << bug
      untagged = Factories.job(repository: repo, issue_number: 2)

      expect(run(field: "tags", op: "contains_none", value: [ bug.id ])).to contain_exactly(untagged)
    end
  end

  describe "attention preset" do
    it "pinned: returns only jobs pinned by the operator" do
      pinned = Factories.job(repository: repo, issue_number: 1)
      Factories.job(repository: repo, issue_number: 2)
      Factories.job_pin(user: user, job: pinned)

      expect(run(field: "attention", op: "is", value: "pinned")).to contain_exactly(pinned)
    end

    it "in_progress: includes WorkUnit-owned running work but excludes queued and paused work" do
      running = Factories.job_record(repository: repo, issue_number: 1, state: "running")
      landing_running = Factories.job_record(repository: repo, issue_number: 2, state: "landing")
      queued_rebase = Factories.job_record(repository: repo, issue_number: 3, state: "approved")
      running_rebase = Factories.job_record(repository: repo, issue_number: 4, state: "approved")
      finished_rebase = Factories.job_record(repository: repo, issue_number: 5, state: "approved")
      landing_queued = Factories.job_record(repository: repo, issue_number: 6, state: "landing")
      running_merge_train = Factories.job_record(repository: repo, issue_number: 8, state: "approved")
      running_retry = Factories.job_record(repository: repo, issue_number: 9, state: "failed")
      running_ci_failure = Factories.job_record(repository: repo, issue_number: 10, state: "implemented")
      old_running_workflow = Factories.job_record(repository: repo, issue_number: 11, state: "approved")
      paused_running = Factories.job_record(repository: repo, issue_number: 12, state: "approved")
      manually_paused_running = Factories.job_record(repository: repo, issue_number: 13, state: "running", manual_paused: true, manual_paused_at: Time.current, manual_paused_by_user: user)
      blocked_work_unit = Factories.job_record(repository: repo, issue_number: 14, state: "running")
      work_unit_owner = Factories.job_record(repository: repo, issue_number: 15, state: "running")
      work_unit_member = Factories.job_record(repository: repo, issue_number: 16, state: "approved")
      work_unit_repairing = Factories.job_record(repository: repo, issue_number: 17, state: "failed")
      queued_repairing = Factories.job_record(repository: repo, issue_number: 18, state: "approved")
      Factories.job_record(repository: repo, issue_number: 7, state: "approved")

      create_queued_work_unit_for(queued_rebase, kind: "rebase")
      create_running_work_unit_for(running_rebase, kind: "rebase")
      Workflow.create!(job: finished_rebase, trigger_kind: "rebase", state: "succeeded")
      create_running_work_unit_for(landing_running, kind: "auto_merge")
      create_queued_work_unit_for(landing_queued, kind: "auto_merge")
      create_running_work_unit_for(running_merge_train, kind: "merge_train")
      create_running_work_unit_for(running_retry, kind: "retry")
      create_running_work_unit_for(running_ci_failure, kind: "ci_failure")
      Workflow.create!(job: old_running_workflow, trigger_kind: "rebase", state: "running")
      Workflow.create!(job: old_running_workflow, trigger_kind: "retry", state: "succeeded")
      Workflow.create!(
        job: paused_running,
        trigger_kind: "initial",
        state: "running",
        artifacts: { "pause_reason" => "workflow_admission_budget" }
      )
      create_blocked_work_unit_for(blocked_work_unit)
      create_running_work_unit_for(work_unit_owner, member_jobs: [ work_unit_owner, work_unit_member ], kind: "merge_train")
      create_running_work_unit_for(work_unit_repairing, kind: "ci_failure")
      create_queued_work_unit_for(queued_repairing, kind: "ci_failure")

      expect(run(field: "attention", op: "is", value: "in_progress")).to contain_exactly(
        running,
        landing_running,
        running_rebase,
        running_merge_train,
        running_retry,
        running_ci_failure,
        work_unit_owner,
        work_unit_member,
        work_unit_repairing
      )
      expect(run(field: "attention", op: "is", value: "in_progress")).not_to include(manually_paused_running)
      expect(run(field: "attention", op: "is", value: "in_progress")).not_to include(queued_repairing)
    end

    it "in_progress: ignores legacy landing workflows" do
      stale_legacy = Factories.job_record(repository: repo, issue_number: 18, state: "landing")
      work_unit_owner = Factories.job_record(repository: repo, issue_number: 19, state: "landing")

      Workflow.create!(job: stale_legacy, trigger_kind: "auto_merge", state: "running")
      create_running_work_unit_for(work_unit_owner, kind: "auto_merge")

      expect(run(field: "attention", op: "is", value: "in_progress")).to contain_exactly(work_unit_owner)
    end

    it "queued: returns queued jobs and jobs whose latest workflow is queued" do
      queued = Factories.job_record(repository: repo, issue_number: 21, state: "queued")
      queued_rebase = Factories.job_record(repository: repo, issue_number: 22, state: "approved")
      queued_landing = Factories.job_record(repository: repo, issue_number: 23, state: "landing")
      Factories.job_record(repository: repo, issue_number: 24, state: "approved")
      running_rebase = Factories.job_record(repository: repo, issue_number: 25, state: "approved")
      superseded_queue = Factories.job_record(repository: repo, issue_number: 26, state: "approved")
      Factories.job_record(repository: repo, issue_number: 27, state: "queued", manual_paused: true, manual_paused_at: Time.current, manual_paused_by_user: user)

      create_queued_work_unit_for(queued_rebase, kind: "rebase")
      Workflow.create!(job: queued_landing, trigger_kind: "auto_merge", state: "queued")
      create_running_work_unit_for(running_rebase, kind: "rebase")
      create_queued_work_unit_for(superseded_queue, kind: "rebase")
      create_running_work_unit_for(superseded_queue, kind: "rebase")

      expect(run(field: "attention", op: "is", value: "queued")).to contain_exactly(
        queued,
        queued_rebase
      )
    end

    it "paused: returns manually paused jobs and WorkUnit-paused jobs" do
      manual = Factories.job_record(repository: repo, issue_number: 28, state: "queued", manual_paused: true, manual_paused_at: Time.current, manual_paused_by_user: user)
      work_unit_paused = Factories.job_record(repository: repo, issue_number: 31, state: "running")
      landing_paused = Factories.job_record(repository: repo, issue_number: 32, state: "landing")
      repair_paused = Factories.job_record(repository: repo, issue_number: 37, state: "failed")
      Factories.job_record(repository: repo, issue_number: 30, state: "queued")
      create_blocked_work_unit_for(work_unit_paused)
      create_blocked_work_unit_for(landing_paused, kind: "auto_merge")
      create_blocked_work_unit_for(repair_paused, kind: "ci_failure")

      expect(run(field: "attention", op: "is", value: "paused")).to contain_exactly(manual, work_unit_paused, repair_paused)
    end

    it "paused: ignores legacy landing start-block artifacts" do
      stale_legacy = Factories.job_record(repository: repo, issue_number: 38, state: "landing")
      work_unit_paused = Factories.job_record(repository: repo, issue_number: 39, state: "running")

      Workflow.create!(
        job: stale_legacy,
        trigger_kind: "auto_merge",
        state: "running",
        artifacts: { "start_blocked_reason" => "workflow_admission_budget" }
      )
      create_blocked_work_unit_for(work_unit_paused)

      expect(run(field: "attention", op: "is", value: "paused")).to contain_exactly(work_unit_paused)
      expect(run(field: "has_start_blocked_reason", op: "is_true", value: nil)).to contain_exactly(work_unit_paused)
    end

    it "paused: excludes jobs blocked only for a dependency-wait reason" do
      genuinely_paused = Factories.job_record(repository: repo, issue_number: 40, state: "running")
      create_blocked_work_unit_for(genuinely_paused, blocked_reason: "admission_control")

      WorkUnit::DEPENDENCY_BLOCKED_REASONS.each_with_index do |reason, index|
        dependency_waiting = Factories.job_record(repository: repo, issue_number: 41 + index, state: "approved")
        create_blocked_work_unit_for(dependency_waiting, blocked_reason: reason)

        result = run(field: "attention", op: "is", value: "paused")
        expect(result).not_to include(dependency_waiting), "expected #{reason.inspect}-blocked job to be excluded from paused"
      end

      expect(run(field: "attention", op: "is", value: "paused")).to contain_exactly(genuinely_paused)
    end

    it "queued: excludes jobs with a running infrastructure workflow (e.g. main_grader)" do
      plain_queued = Factories.job_record(repository: repo, issue_number: 30, state: "queued")
      grader_running = Factories.job_record(repository: repo, issue_number: 31, state: "queued")
      grader_done = Factories.job_record(repository: repo, issue_number: 32, state: "queued")

      create_running_work_unit_for(grader_running, kind: "main_grader")
      Workflow.create!(job: grader_done, trigger_kind: "main_grader", state: "succeeded")

      expect(run(field: "attention", op: "is", value: "queued")).to contain_exactly(
        plain_queued,
        grader_done
      )
    end

    it "in_progress: includes queued jobs with a running infrastructure workflow" do
      grader_running = Factories.job_record(repository: repo, issue_number: 33, state: "queued")
      plain_queued = Factories.job_record(repository: repo, issue_number: 34, state: "queued")

      create_running_work_unit_for(grader_running, kind: "main_grader")

      expect(run(field: "attention", op: "is", value: "in_progress")).to include(grader_running)
      expect(run(field: "attention", op: "is", value: "in_progress")).not_to include(plain_queued)
    end

    it "queued: excludes queued jobs with running infrastructure WorkUnit membership" do
      grader_running = Factories.job_record(repository: repo, issue_number: 35, state: "queued")
      plain_queued = Factories.job_record(repository: repo, issue_number: 36, state: "queued")
      create_running_work_unit_for(grader_running, kind: "main_grader")

      expect(run(field: "attention", op: "is", value: "queued")).to contain_exactly(plain_queued)
      expect(run(field: "attention", op: "is", value: "in_progress")).to include(grader_running)
    end

    it "inbox: returns only actionable review, repair, and idle feedback jobs" do
      failed = Factories.job_record(repository: repo, issue_number: 11, state: "failed")
      implemented = Factories.job_record(repository: repo, issue_number: 12, state: "implemented")
      invalid = Factories.job_record(repository: repo, issue_number: 13, state: "triaging", validity: "duplicate")
      landing_failed = Factories.job_record(
        repository: repo,
        issue_number: 18,
        state: "approved",
        landing_failure_reason: "auto_merge: required grader failed"
      )
      unread_feedback = Factories.job_record(
        repository: repo,
        issue_number: 14,
        state: "approved",
        last_seen_comment_at: 5.minutes.ago,
        last_feedback_addressed_at: 10.minutes.ago
      )
      active_failed = Factories.job_record(repository: repo, issue_number: 19, state: "failed")
      active_implemented = Factories.job_record(repository: repo, issue_number: 20, state: "implemented")
      repairing_failed = Factories.job_record(repository: repo, issue_number: 21, state: "failed")
      Factories.job_record(repository: repo, issue_number: 15, state: "queued")
      Factories.job_record(
        repository: repo,
        issue_number: 16,
        state: "running",
        last_seen_comment_at: 5.minutes.ago,
        last_feedback_addressed_at: 10.minutes.ago
      )
      Factories.job_record(repository: repo, issue_number: 17, state: "triaging", triaging_reason: "pending_epic_ref")
      create_running_work_unit_for(active_failed, kind: "manual")
      create_queued_work_unit_for(active_implemented, kind: "manual")
      create_running_work_unit_for(repairing_failed, kind: "ci_failure")

      expect(run(field: "attention", op: "is", value: "inbox")).to contain_exactly(
        failed,
        implemented,
        invalid,
        landing_failed,
        unread_feedback
      )
    end

    it "inbox: excludes jobs owned by other users even from a team-wide scope" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user, owner: "acme", name: "other-widgets")
      mine = Factories.job_record(repository: repo, issue_number: 51, state: "implemented")
      Factories.job_record(repository: other_repo, issue_number: 52, state: "implemented", owner_user: other_user)

      expect(run(field: "attention", op: "is", value: "inbox", scope: Job.all)).to contain_exactly(mine)
    end

    it "inbox: includes the operator's own NULL-owner jobs but not other users' (effective ownership)" do
      # Legacy data: jobs created before owner_user_id was populated have a
      # NULL owner. The inbox must still surface the operator's own unowned
      # jobs (fall back to creator) while excluding other users' unowned jobs.
      mine = Factories.job_record(repository: repo, issue_number: 53, state: "implemented")
      mine.update_column(:owner_user_id, nil)

      other_user = Factories.user
      other_repo = Factories.repository(user: other_user, owner: "acme", name: "other-nulls")
      theirs = Factories.job_record(repository: other_repo, issue_number: 54, state: "implemented", user: other_user)
      theirs.update_column(:owner_user_id, nil)

      result = run(field: "attention", op: "is", value: "inbox", scope: Job.all)
      expect(result).to include(mine)
      expect(result).not_to include(theirs)
    end

    it "awaiting_approval: excludes jobs with any active workflows" do
      ready = Factories.job_record(repository: repo, issue_number: 31, state: "implemented")
      queued_feedback = Factories.job_record(repository: repo, issue_number: 32, state: "implemented")
      running_retry = Factories.job_record(repository: repo, issue_number: 33, state: "implemented")
      completed_feedback = Factories.job_record(repository: repo, issue_number: 34, state: "implemented")

      create_queued_work_unit_for(queued_feedback, kind: "pr_comment")
      create_running_work_unit_for(running_retry, kind: "retry")
      Workflow.create!(job: completed_feedback, trigger_kind: "pr_comment", state: "succeeded")

      expect(run(field: "attention", op: "is", value: "awaiting_approval")).to contain_exactly(
        ready,
        completed_feedback
      )
    end

    it "blocked: excludes jobs with active (running or queued) workflows" do
      # Genuinely blocked: unmergeable PR, no active workflow
      blocked_pr = Factories.job_record(repository: repo, issue_number: 61, state: "approved", pr_mergeable: false)

      # Not blocked: unmergeable PR, but a running workflow is actively fixing it
      running_workflow = Factories.job_record(repository: repo, issue_number: 62, state: "running", pr_mergeable: false)
      create_running_work_unit_for(running_workflow, kind: "auto_merge")

      # Not blocked: unmergeable PR, but a queued workflow is about to run
      queued_workflow = Factories.job_record(repository: repo, issue_number: 63, state: "approved", pr_mergeable: false)
      create_queued_work_unit_for(queued_workflow, kind: "rebase")

      # Not blocked: PR is mergeable
      Factories.job_record(repository: repo, issue_number: 64, state: "approved", pr_mergeable: true)

      expect(run(field: "attention", op: "is", value: "blocked")).to contain_exactly(blocked_pr)
    end

    it "just_failed: returns failed jobs that require operator action" do
      failed = Factories.job(repository: repo, issue_number: 1)
      failed.update!(state: "failed")
      landing_failed = Factories.job_record(
        repository: repo,
        issue_number: 3,
        state: "implemented",
        landing_failure_reason: "auto_merge: required grader failed"
      )
      merge_train_failed = Factories.job_record(
        repository: repo,
        issue_number: 4,
        state: "approved",
        landing_failure_reason: "merge_train failed"
      )
      landing_retrying = Factories.job_record(
        repository: repo,
        issue_number: 6,
        state: "approved",
        landing_failure_reason: "landing start blocked: workflow admission budget"
      )
      repair_running = Factories.job_record(repository: repo, issue_number: 7, state: "failed")
      repair_blocked = Factories.job_record(repository: repo, issue_number: 8, state: "failed")
      Factories.job_record(
        repository: repo,
        issue_number: 5,
        state: "closed",
        landing_failure_reason: "old landing failure"
      )
      Factories.job(repository: repo, issue_number: 2)
      create_running_work_unit_for(repair_running, kind: "ci_failure")
      create_blocked_work_unit_for(repair_blocked, kind: "ci_failure")

      expect(run(field: "attention", op: "is", value: "just_failed")).to contain_exactly(failed)
      expect(run(field: "attention", op: "is", value: "just_failed")).not_to include(landing_failed, merge_train_failed, landing_retrying, repair_running, repair_blocked)
    end

    it "has_landing_failure: returns open jobs with a substantive landing failure reason" do
      landing_failed = Factories.job_record(
        repository: repo,
        issue_number: 41,
        state: "approved",
        landing_failure_reason: "auto_merge: required grader failed"
      )
      closed_landing_failure = Factories.job_record(
        repository: repo,
        issue_number: 42,
        state: "closed",
        landing_failure_reason: "old landing failure"
      )
      landing_retrying = Factories.job_record(
        repository: repo,
        issue_number: 44,
        state: "approved",
        landing_failure_reason: "landing start blocked: workflow admission budget"
      )
      healthy = Factories.job_record(repository: repo, issue_number: 43, state: "approved")

      expect(run(field: "has_landing_failure", op: "is_true", value: nil)).to contain_exactly(landing_failed)
      expect(run(field: "has_landing_failure", op: "is_false", value: nil)).to contain_exactly(
        closed_landing_failure,
        landing_retrying,
        healthy
      )
    end

    it "merged_this_week: returns recently-merged closed threads" do
      merged = Factories.job(repository: repo, issue_number: 1)
      merged.update!(state: "closed", closure_reason: "pr_merged", finished_at: 2.days.ago)
      Factories.job(repository: repo, issue_number: 2)

      expect(run(field: "attention", op: "is", value: "merged_this_week")).to contain_exactly(merged)
    end
  end

  describe "job_type" do
    before do
      Feature.find_or_create_by!(slug: "agent_insights") { |f|
        f.category = "Labs"; f.name = "Agent Insights"
      }.update!(enabled: true)
    end

    it "is:user returns only user-facing jobs (issue, direct) and excludes agent_insight and deploy" do
      issue_job   = Factories.job_record(repository: repo, issue_number: 1, kind: "issue")
      direct_job  = Factories.job_record(repository: repo, issue_number: nil, kind: "direct")
      Factories.job_record(repository: repo, issue_number: nil, kind: "main_grader")
      Factories.job_record(repository: repo, issue_number: nil, kind: "agent_insight")
      Factories.job_record(repository: repo, issue_number: nil, kind: "deploy")

      expect(run(field: "job_type", op: "is", value: "user")).to contain_exactly(issue_job, direct_job)
    end

    it "is:system returns main_grader, agent_insight, and deploy jobs" do
      Factories.job_record(repository: repo, issue_number: 1, kind: "issue")
      grader_job  = Factories.job_record(repository: repo, issue_number: nil, kind: "main_grader")
      insight_job = Factories.job_record(repository: repo, issue_number: nil, kind: "agent_insight")
      deploy_job  = Factories.job_record(repository: repo, issue_number: nil, kind: "deploy")

      expect(run(field: "job_type", op: "is", value: "system")).to contain_exactly(grader_job, insight_job, deploy_job)
    end

    it "is_not:user returns system jobs including agent_insight and deploy" do
      Factories.job_record(repository: repo, issue_number: 1, kind: "issue")
      grader_job  = Factories.job_record(repository: repo, issue_number: nil, kind: "main_grader")
      insight_job = Factories.job_record(repository: repo, issue_number: nil, kind: "agent_insight")
      deploy_job  = Factories.job_record(repository: repo, issue_number: nil, kind: "deploy")

      expect(run(field: "job_type", op: "is_not", value: "user")).to contain_exactly(grader_job, insight_job, deploy_job)
    end
  end
end
