require "rails_helper"

RSpec.describe WorkEngine::RepairExecutor do
  RepairResult = Data.define(:repair_plans)

  let(:job) { Factories.job }
  let(:workflow) { job.latest_workflow }

  def repair_plan(action:, target:)
    WorkEngine::RepairPlanner::Plan.new(
      issue_kind: "running_workflow_without_active_descendants",
      action: action,
      auto_executable: true,
      target_type: target.class.name,
      target_id: target.id,
      affected_ids: {},
      execution_steps: [],
      preconditions: {},
      reason: "test"
    )
  end

  it "fails a running workflow with an uncleared retry barrier instead of marking it succeeded" do
    workflow.steps.destroy_all
    loop_id = SecureRandom.uuid
    fanout = Step.create!(workflow: workflow, kind: "grader_fanout", position: 1, loop_id: loop_id, state: "succeeded", finished_at: 5.minutes.ago)
    collect = Step.create!(workflow: workflow, kind: "grader_collect", position: 2, loop_id: loop_id, state: "cancelled", finished_at: 4.minutes.ago)
    fanout.update!(next_step: collect)
    workflow.update_columns(state: "running", started_at: 10.minutes.ago, finished_at: nil)

    result = described_class.call(
      result: RepairResult.new([
        repair_plan(action: "finish_workflow_from_terminal_descendants", target: workflow)
      ])
    )

    expect(result.first).to have_attributes(status: "applied")
    expect(result.first.message).to include("marked #{workflow.slug} failed")
    expect(workflow.reload).to be_failed
  end

  it "cancels an obsolete requested WorkIntent instead of launching it after its Job closes" do
    target = Factories.job_record(user: job.user, repository: job.repository, issue_number: 501)
    intent = WorkIntent.create!(
      kind: "initial",
      state: "requested",
      repository: target.repository,
      scope_type: "job",
      scope_id: target.id,
      actor: target.user,
      source_type: "spec"
    )
    target.update_columns(state: "closed", finished_at: Time.current, closure_reason: "pr_merged")

    result = described_class.call(
      result: RepairResult.new([
        repair_plan(action: "launch_requested_work_intent", target: intent)
      ])
    )

    expect(result.first).to have_attributes(
      status: "applied",
      message: "cancelled #{intent.slug} because #{target.slug} is closed"
    )
    expect(intent.reload).to be_cancelled
    expect(target.workflows).to be_empty
  end

  it "reports a requested WorkIntent as skipped when launch creates no Run" do
    target = Factories.job_record(user: job.user, repository: job.repository, state: "backlog", issue_number: 502)
    intent = WorkIntent.create!(
      kind: "initial",
      state: "requested",
      repository: target.repository,
      scope_type: "job",
      scope_id: target.id,
      actor: target.user,
      source_type: "spec"
    )

    result = described_class.call(
      result: RepairResult.new([
        repair_plan(action: "launch_requested_work_intent", target: intent)
      ])
    )

    expect(result.first).to have_attributes(
      status: "skipped",
      message: "#{intent.slug} did not start: #{StepDispatcher::BACKLOG_BLOCK_REASON}"
    )
    expect(intent.reload).to be_requested
    expect(target.workflows.last.first_step.runs).to be_empty
  end

  # Regression: a merge train owns its members through `merge_train_members`,
  # but the train's single WorkUnit is instantiated with only the tip job, so
  # every other member has no WorkUnitMember row. `stranded?` asked the
  # WorkUnit question alone and therefore deferred live train members out of
  # `landing` while the train was still grading -- which the land step then
  # rejected as "members not in :landing", throwing away the whole assembly.
  describe "release_externally_blocked_landing_slot with merge train members" do
    def release_plan(unit)
      WorkEngine::RepairPlanner::Plan.new(
        issue_kind: "externally_blocked_landing_slot",
        action: "release_externally_blocked_landing_slot",
        auto_executable: true,
        target_type: unit.class.name,
        target_id: unit.id,
        affected_ids: {},
        execution_steps: [],
        preconditions: { "work_unit_id" => unit.id },
        reason: "test"
      )
    end

    def blocked_landing_unit_for(member_job)
      intent = WorkIntent.create!(
        kind: "job_bundle",
        state: "requested",
        scope_type: "job",
        scope_id: member_job.id,
        repository: member_job.repository,
        actor: member_job.user,
        requested_at: Time.current,
        source_type: "spec"
      )
      unit = WorkUnit.create!(
        work_intent: intent,
        kind: "job_bundle",
        state: "blocked",
        blocked_reason: "no_capable_worker",
        scope_type: "job",
        scope_id: member_job.id,
        repository: member_job.repository
      )
      unit.work_unit_members.create!(job: member_job, role: "primary")
      unit.work_unit_locks.create!(lock_key: "#{WorkUnit::LANDING_LOCK_KEY_PREFIX}repository:#{member_job.repository_id}")
      unit
    end

    let(:member_job) do
      Factories.job_record(user: job.user, repository: job.repository, issue_number: 777).tap do |j|
        j.update_columns(state: "landing", approved_at: Time.current)
      end
    end

    it "leaves a member of an active merge train in landing" do
      unit = blocked_landing_unit_for(member_job)
      train = MergeTrain.create!(repository: job.repository, base_branch: "main", state: "grading", priority: "medium")
      MergeTrainMember.create!(merge_train: train, job: member_job, position: 0)

      described_class.call(
        result: RepairResult.new([
          release_plan(unit)
        ])
      )

      expect(member_job.reload.state).to eq("landing")
    end

    it "still defers a landing Job that no active train owns" do
      unit = blocked_landing_unit_for(member_job)

      described_class.call(
        result: RepairResult.new([
          release_plan(unit)
        ])
      )

      expect(member_job.reload.state).to eq("approved")
    end
  end
end
