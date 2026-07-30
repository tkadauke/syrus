require "rails_helper"

RSpec.describe RetryFailedStepEnqueuer do
  it "retries the latest failed step instead of an obsolete earlier failure" do
    job = Factories.job_record(state: "failed")
    workflow = Workflow.create!(job: job, trigger_kind: "initial")
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)

    old_failure = Step.create!(workflow: workflow, kind: "grader_collect", position: 7)
    later_success = Step.create!(workflow: workflow, kind: "summarize", position: 22)
    terminal_failure = Step.create!(workflow: workflow, kind: "pr_open", position: 23)
    old_failure.update_columns(state: "failed", started_at: 9.minutes.ago, finished_at: 8.minutes.ago)
    later_success.update_columns(state: "succeeded", started_at: 5.minutes.ago, finished_at: 4.minutes.ago)
    terminal_failure.update_columns(state: "failed", started_at: 2.minutes.ago, finished_at: 1.minute.ago)

    result = described_class.call(workflow: workflow)

    expect(result).to be_success
    expect(result.step).to eq(terminal_failure)
    expect(terminal_failure.reload).to be_queued
    expect(terminal_failure.runs.last).to eq(result.run)
    expect(old_failure.reload).to be_failed
    expect(old_failure.runs).to be_empty
  end

  %w[merge_train_build merge_train_land].each do |failed_step_kind|
    it "rebuilds a failed merge-train instead of retrying the old #{failed_step_kind} step in place" do
      user = Factories.user(github_token: "ghp_test")
      repository = Factories.repository(user: user, auto_merge_enabled: true)
      epic = Factories.epic(user: user, repository: repository, state: "in_progress", reconciliation_mode: "none")
      job = Factories.job_record(
        user: user,
        repository: repository,
        epic: epic,
        state: "approved",
        pr_number: 321,
        branch_name: "syrus/issue-321"
      )
      train = MergeTrain.create!(
        epic: epic,
        repository: repository,
        base_branch: "master",
        state: "failed",
        failure_reason: "merge_train failed",
        finished_at: 1.minute.ago
      )
      MergeTrainMember.create!(merge_train: train, job: job, position: 0, state: "failed")
      workflow = Workflow.create!(job: job, trigger_kind: "merge_train", artifacts: { "merge_train_id" => train.id })
      workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
      failed_step = Step.create!(workflow: workflow, kind: failed_step_kind, position: 5)
      failed_step.update_columns(state: "failed", started_at: 2.minutes.ago, finished_at: 1.minute.ago)

      AppSetting.current.update!(merge_train_enabled: true)
      allow(StepDispatcher).to receive(:start_workflow) do |new_workflow|
        new_workflow.first_step.runs.create!(
          job: new_workflow.job,
          trigger_kind: new_workflow.trigger_kind,
          agent_provider: new_workflow.agent_provider
        )
      end

      result = described_class.call(workflow: workflow)

      expect(result).to be_success
      expect(result.workflow).not_to eq(workflow)
      expect(result.workflow.trigger_kind).to eq("merge_train")
      expect(result.step.kind).to eq("merge_train_assemble")
      expect(result.run.step).to eq(result.step)
      expect(workflow.reload).to be_failed
      expect(failed_step.reload).to be_failed
      expect(failed_step.runs).to be_empty
      expect(job.reload).to be_landing
    end
  end

  it "recovers and re-approves failed members from the old merge-train before rebuilding" do
    user = Factories.user(github_token: "ghp_test")
    repository = Factories.repository(user: user, auto_merge_enabled: true)
    epic = Factories.epic(user: user, repository: repository, state: "in_progress", reconciliation_mode: "none")
    job = Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      state: "failed",
      pr_number: 321,
      branch_name: "syrus/issue-321",
      approved_at: nil,
      approved_via: "operator",
      landing_failure_reason: "merge_train failed"
    )
    train = MergeTrain.create!(
      epic: epic,
      repository: repository,
      base_branch: "master",
      state: "failed",
      failure_reason: "merge_train failed",
      finished_at: 1.minute.ago
    )
    MergeTrainMember.create!(merge_train: train, job: job, position: 0, state: "failed")
    workflow = Workflow.create!(job: job, trigger_kind: "merge_train", artifacts: { "merge_train_id" => train.id })
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
    land_step = Step.create!(workflow: workflow, kind: "merge_train_land", position: 5)
    land_step.update_columns(state: "failed", started_at: 2.minutes.ago, finished_at: 1.minute.ago)

    AppSetting.current.update!(merge_train_enabled: true)
    allow(StepDispatcher).to receive(:start_workflow) do |new_workflow|
      new_workflow.first_step.runs.create!(
        job: new_workflow.job,
        trigger_kind: new_workflow.trigger_kind,
        agent_provider: new_workflow.agent_provider
      )
    end

    result = described_class.call(workflow: workflow)

    expect(result).to be_success
    expect(result.workflow).not_to eq(workflow)
    expect(result.workflow.trigger_kind).to eq("merge_train")
    expect(job.reload).to be_landing
    expect(job.approved_at).to be_present
    expect(job.approved_via).to eq("operator")
    expect(job.landing_failure_reason).to be_nil
  end

  it "explains why a failed merge-train cannot be rebuilt" do
    user = Factories.user(github_token: "ghp_test")
    repository = Factories.repository(user: user, auto_merge_enabled: true)
    epic = Factories.epic(user: user, repository: repository, state: "in_progress", reconciliation_mode: "none")
    job = Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      state: "implemented",
      pr_number: 321,
      branch_name: "syrus/issue-321"
    )
    blocker = Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      state: "implemented",
      pr_number: nil,
      branch_name: "syrus/issue-322"
    )
    train = MergeTrain.create!(
      epic: epic,
      repository: repository,
      base_branch: "master",
      state: "failed",
      failure_reason: "merge_train: missing built base SHA; rebuild required",
      finished_at: 1.minute.ago
    )
    MergeTrainMember.create!(merge_train: train, job: job, position: 0, state: "failed")
    workflow = Workflow.create!(job: job, trigger_kind: "merge_train", artifacts: { "merge_train_id" => train.id })
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
    land_step = Step.create!(workflow: workflow, kind: "merge_train_land", position: 5)
    land_step.update_columns(state: "failed", started_at: 2.minutes.ago, finished_at: 1.minute.ago)

    AppSetting.current.update!(merge_train_enabled: true)

    result = described_class.call(workflow: workflow)

    expect(result).not_to be_success
    expect(job.reload).to be_approved
    expect(result.error).to eq("Epic is not ready for a merge-train rebuild: child Jobs without a PR: #{blocker.slug}.")
  end

  (Workflow::LANDING_TRIGGER_KINDS - [ "merge_train" ]).each do |trigger_kind|
    it "clears landing_failure_reason on the job when retrying a failed #{trigger_kind} step" do
      job = Factories.job_record(state: "implemented", landing_failure_reason: "#{trigger_kind} workflow failed")
      workflow = Workflow.create!(job: job, trigger_kind: trigger_kind)
      workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
      step = Step.create!(workflow: workflow, kind: "grader_collect", position: 1)
      step.update_columns(state: "failed", started_at: 9.minutes.ago, finished_at: 8.minutes.ago)

      result = described_class.call(workflow: workflow)

      expect(result).to be_success
      expect(job.reload.landing_failure_reason).to be_nil
    end
  end

  it "does not clear landing_failure_reason when retrying a non-landing workflow step" do
    job = Factories.job_record(state: "failed", landing_failure_reason: "old landing failure")
    workflow = Workflow.create!(job: job, trigger_kind: "initial")
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
    step = Step.create!(workflow: workflow, kind: "pr_open", position: 1)
    step.update_columns(state: "failed", started_at: 9.minutes.ago, finished_at: 8.minutes.ago)

    result = described_class.call(workflow: workflow)

    expect(result).to be_success
    expect(job.reload.landing_failure_reason).to eq("old landing failure")
  end
end
