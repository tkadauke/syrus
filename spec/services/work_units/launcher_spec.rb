require "rails_helper"

RSpec.describe WorkUnits::Launcher do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }

  before { clear_enqueued_jobs }
  after { clear_enqueued_jobs }

  it "instantiates the workflow template declared by the work definition" do
    workflow = described_class.instantiate(kind: "manual_visual_review", job: job)

    expect(workflow).to be_persisted
    expect(workflow).to have_attributes(job: job, trigger_kind: "manual_visual_review")
    expect(workflow.steps.pluck(:kind)).to eq(%w[prepare visual_review])
  end

  it "creates a shadow work intent and unit for the workflow attempt" do
    workflow = described_class.instantiate(kind: "manual_visual_review", job: job)
    unit = workflow.work_unit
    intent = unit.work_intent

    expect(intent).to have_attributes(
      kind: "manual_visual_review",
      state: "requested",
      repository: repository,
      scope_type: "job",
      scope_id: job.id,
      priority: job.priority,
      actor: user,
      source_type: "workflow_launch"
    )
    expect(unit).to have_attributes(
      kind: "manual_visual_review",
      state: "queued",
      repository: repository,
      scope_type: "job",
      scope_id: job.id,
      workflow: workflow
    )
    expect(unit.work_unit_members.map { |member| [ member.job_id, member.role ] }).to eq([[ job.id, "primary" ]])
    expect(unit.work_unit_locks.pluck(:lock_key)).to contain_exactly("job:#{job.id}")
  end

  it "creates shadow ownership for normal initial jobs" do
    workflow = described_class.instantiate(kind: "initial", job: job)

    expect(workflow.work_unit).to have_attributes(kind: "initial", scope_type: "job", scope_id: job.id)
    expect(workflow.work_unit.work_intent).to have_attributes(kind: "initial", scope_type: "job", scope_id: job.id)
  end

  it "does not start workflow runs for backlogged jobs" do
    backlogged = Factories.job_record(user: user, repository: repository, state: "backlog")
    workflow = described_class.instantiate(kind: "initial", job: backlogged)

    result = described_class.start!(workflow)

    expect(result).to have_attributes(status: "not_started", run: nil)
    expect(workflow.first_step.runs).to be_empty
    expect(WorkUnits::StartBlock.for(workflow.reload)).to be_blocked_for(StepDispatcher::BACKLOG_BLOCK_REASON)
  end

  it "rejects a repeated non-idempotent launch of the same kind while the first is still active" do
    first = described_class.instantiate(kind: "manual_visual_review", job: job)

    expect {
      described_class.instantiate(kind: "manual_visual_review", job: job)
    }.to raise_error(WorkUnits::Launcher::LockConflict, /job:#{job.id}:manual_visual_review/)

    expect(WorkUnit.where(kind: "manual_visual_review", scope_type: "job", scope_id: job.id).count).to eq(1)
    expect(first.work_unit).to be_active
  end

  # JOB-4235: WorkUnits::Launcher#create_lock! used to only raise
  # LockConflict for landing kinds; every other kind silently swallowed a
  # conflict and let a second WorkUnit + Workflow + Step chain materialize
  # anyway, which would go on to actually run once the first unit's lock
  # released. These specs pin the fix for the kinds called out in the bug
  # report: two concurrent triggers for the same Job/kind must produce
  # exactly one Workflow, whether the conflict is same-kind (the DB-level
  # active_dedup_key backstop) or cross-kind sharing the same "job:<id>"
  # lock (the app-level create_lock! check).
  describe "duplicate follow-up workflow prevention" do
    it "produces exactly one chat_feedback Workflow for two concurrent triggers" do
      described_class.instantiate(kind: "chat_feedback", job: job)

      expect {
        expect { described_class.instantiate(kind: "chat_feedback", job: job) }
          .to raise_error(WorkUnits::Launcher::LockConflict)
      }.not_to change { job.workflows.where(trigger_kind: "chat_feedback").count }

      expect(job.workflows.where(trigger_kind: "chat_feedback").count).to eq(1)
    end

    it "produces exactly one pr_comment Workflow for two concurrent triggers" do
      described_class.instantiate(kind: "pr_comment", job: job)

      expect {
        expect { described_class.instantiate(kind: "pr_comment", job: job) }
          .to raise_error(WorkUnits::Launcher::LockConflict)
      }.not_to change { job.workflows.where(trigger_kind: "pr_comment").count }

      expect(job.workflows.where(trigger_kind: "pr_comment").count).to eq(1)
    end

    it "produces exactly one ci_failure Workflow for two concurrent triggers" do
      described_class.instantiate(kind: "ci_failure", job: job)

      expect {
        expect { described_class.instantiate(kind: "ci_failure", job: job) }
          .to raise_error(WorkUnits::Launcher::LockConflict)
      }.not_to change { job.workflows.where(trigger_kind: "ci_failure").count }

      expect(job.workflows.where(trigger_kind: "ci_failure").count).to eq(1)
    end

    it "produces exactly one rebase Workflow for two concurrent triggers" do
      described_class.instantiate(kind: "rebase", job: job, base_branch: "main")

      expect {
        expect { described_class.instantiate(kind: "rebase", job: job, base_branch: "main") }
          .to raise_error(WorkUnits::Launcher::LockConflict)
      }.not_to change { job.workflows.where(trigger_kind: "rebase").count }

      expect(job.workflows.where(trigger_kind: "rebase").count).to eq(1)
    end

    it "produces exactly one retry Workflow for two concurrent triggers" do
      described_class.instantiate(kind: "retry", job: job)

      expect {
        expect { described_class.instantiate(kind: "retry", job: job) }
          .to raise_error(WorkUnits::Launcher::LockConflict)
      }.not_to change { job.workflows.where(trigger_kind: "retry").count }

      expect(job.workflows.where(trigger_kind: "retry").count).to eq(1)
    end

    it "rejects a cross-kind conflict sharing the same job lock (pr_comment vs. chat_feedback)" do
      described_class.instantiate(kind: "chat_feedback", job: job)

      expect {
        described_class.instantiate(kind: "pr_comment", job: job)
      }.to raise_error(WorkUnits::Launcher::LockConflict, /job:#{job.id}/)

      expect(job.workflows.where(trigger_kind: "pr_comment").count).to eq(0)
    end
  end

  it "blocks feedback workflows for sibling jobs in the same epic" do
    epic = Factories.epic(user: user, repository: repository)
    first_job = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 101)
    second_job = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 102)
    first = described_class.instantiate(kind: "pr_comment", job: first_job)

    second = described_class.instantiate(kind: "chat_feedback", job: second_job)
    result = described_class.start!(second)

    expect(first.work_unit.work_unit_locks.pluck(:lock_key)).to include("epic_feedback:#{epic.id}")
    expect(second.work_unit.work_unit_locks.pluck(:lock_key)).to contain_exactly("job:#{second_job.id}")
    expect(result).to be_blocked
    expect(result.reason).to eq("active_work_lock")
    expect(result.work_unit.blocked_details).to include(
      "lock_key" => "epic_feedback:#{epic.id}",
      "work_unit_id" => first.work_unit.id
    )
  end

  it "allows feedback workflows for jobs in different epics to own different feedback locks" do
    first_epic = Factories.epic(user: user, repository: repository)
    second_epic = Factories.epic(user: user, repository: repository)
    first_job = Factories.job_record(user: user, repository: repository, epic: first_epic, issue_number: 101)
    second_job = Factories.job_record(user: user, repository: repository, epic: second_epic, issue_number: 102)

    first = described_class.instantiate(kind: "pr_comment", job: first_job)
    second = described_class.instantiate(kind: "chat_feedback", job: second_job)

    expect(first.work_unit.work_unit_locks.pluck(:lock_key)).to contain_exactly("job:#{first_job.id}", "epic_feedback:#{first_epic.id}")
    expect(second.work_unit.work_unit_locks.pluck(:lock_key)).to contain_exactly("job:#{second_job.id}", "epic_feedback:#{second_epic.id}")
  end

  it "creates a fresh intent and unit for repeated non-idempotent launches after the first unit is terminal" do
    first = described_class.instantiate(kind: "manual_visual_review", job: job)
    first.work_unit.mark_terminal!("cancelled")

    second = described_class.instantiate(kind: "manual_visual_review", job: job)

    expect(second).not_to eq(first)
    expect(second.work_unit).not_to eq(first.work_unit)
    expect(second.work_unit.work_intent).not_to eq(first.work_unit.work_intent)
  end

  it "reuses the active workflow for an idempotent launch" do
    first = described_class.instantiate(kind: "manual_visual_review", job: job, idempotency_key: "manual-visual-review:#{job.id}")
    second = described_class.instantiate(kind: "manual_visual_review", job: job, idempotency_key: "manual-visual-review:#{job.id}")

    expect(second).to eq(first)
    expect(WorkIntent.where(idempotency_key: "manual-visual-review:#{job.id}").count).to eq(1)
    expect(first.work_unit.work_intent.work_units.count).to eq(1)
  end

  it "creates a new unit for the same idempotent intent after the prior unit is terminal" do
    first = described_class.instantiate(kind: "manual_visual_review", job: job, idempotency_key: "manual-visual-review:#{job.id}")
    first.work_unit.mark_terminal!("failed")

    second = described_class.instantiate(kind: "manual_visual_review", job: job, idempotency_key: "manual-visual-review:#{job.id}")

    expect(second).not_to eq(first)
    expect(second.work_unit.work_intent).to eq(first.work_unit.work_intent)
    expect(second.work_unit).not_to eq(first.work_unit)
  end

  it "passes artifacts and agent provider through to the workflow template" do
    workflow = described_class.instantiate(
      kind: "ci_failure",
      job: job,
      artifacts: { "head_sha" => "abc123" },
      agent_provider: "codex"
    )

    expect(workflow.trigger_kind).to eq("ci_failure")
    expect(workflow.agent_provider).to eq("codex")
    expect(workflow.artifact("head_sha")).to eq("abc123")
  end

  it "snapshots launch artifacts on the work intent for later relaunches" do
    workflow = described_class.instantiate(
      kind: "ci_failure",
      job: job,
      artifacts: { "head_sha" => "abc123", "base_sha" => "base456" }
    )

    expect(workflow.work_unit.work_intent.payload_artifacts).to include(
      "head_sha" => "abc123",
      "base_sha" => "base456"
    )
  end

  it "uses work intent payload artifacts when relaunching an intent" do
    workflow = described_class.instantiate(
      kind: "ci_failure",
      job: job,
      artifacts: { "head_sha" => "abc123", "base_sha" => "base456" },
      idempotency_key: "ci-failure:#{job.id}:abc123"
    )
    intent = workflow.work_unit.work_intent
    workflow.work_unit.mark_terminal!("failed")

    relaunched = described_class.instantiate_intent!(intent)

    expect(relaunched).not_to eq(workflow)
    expect(relaunched.artifact("head_sha")).to eq("abc123")
    expect(relaunched.artifact("base_sha")).to eq("base456")
  end

  it "passes workflow-specific options through to specialized templates" do
    workflow = described_class.instantiate(
      kind: "rebase",
      job: job,
      base_branch: "syrus/parent"
    )

    expect(workflow.trigger_kind).to eq("rebase")
    expect(workflow.artifact(RebaseTarget::BASE_BRANCH_ARTIFACT)).to eq("syrus/parent")
  end

  it "uses maintenance-scoped locks for rebase workflows so they can recover active job work" do
    active = described_class.instantiate(kind: "initial", job: job)

    rebase = described_class.instantiate(kind: "rebase", job: job, base_branch: "main")

    expect(active.work_unit.work_unit_locks.pluck(:lock_key)).to include("job:#{job.id}")
    expect(rebase.work_unit.work_unit_locks.pluck(:lock_key)).to contain_exactly("maintenance:rebase:job:#{job.id}")
  end

  it "does not take the broad repository lock for main repair when the repair-blocking policy is disabled" do
    repository.update!(main_branch_repair_blocks_work: false)
    repair_job = Factories.job_record(user: user, repository: repository)

    workflow = described_class.instantiate(kind: "main_branch_repair", job: repair_job)

    expect(workflow.work_unit.work_unit_locks.pluck(:lock_key)).to contain_exactly(
      "job:#{repair_job.id}",
      "main_branch_repair:repository:#{repository.id}"
    )
  end

  it "keeps the broad repository lock for main repair when the repair-blocking policy is enabled" do
    repository.update!(main_branch_repair_blocks_work: true)
    repair_job = Factories.job_record(user: user, repository: repository)

    workflow = described_class.instantiate(kind: "main_branch_repair", job: repair_job)

    expect(workflow.work_unit.work_unit_locks.pluck(:lock_key)).to include("repository:#{repository.id}")
  end

  it "allows landing work past legacy main-repair repository locks when the repair-blocking policy is disabled" do
    repair_job = Factories.job_record(user: user, repository: repository)
    repair_workflow = described_class.instantiate(kind: "main_branch_repair", job: repair_job)
    repository.update!(main_branch_repair_blocks_work: false)
    first = Factories.job_record(user: user, repository: repository, issue_number: 101, state: "approved")
    second = Factories.job_record(user: user, repository: repository, issue_number: 102, state: "approved")
    train = MergeTrain.create!(repository: repository, base_branch: repository.default_branch, priority: "medium")
    MergeTrainMember.create!(merge_train: train, job: first, position: 0)
    MergeTrainMember.create!(merge_train: train, job: second, position: 1)

    bundle = described_class.instantiate(kind: "job_bundle", job: first, artifacts: { "merge_train_id" => train.id })
    gate_result = WorkUnits::Gates::ActiveWorkLock.call(bundle.work_unit)

    expect(repair_workflow.work_unit.work_unit_locks.pluck(:lock_key)).to include("repository:#{repository.id}")
    expect(gate_result).to be_pass
  end

  it "rolls back landing unit launches when another active unit owns a member lock" do
    first = Factories.job_record(user: user, repository: repository, issue_number: 101, state: "approved")
    second = Factories.job_record(user: user, repository: repository, issue_number: 102, state: "approved")
    train = MergeTrain.create!(repository: repository, base_branch: repository.default_branch, priority: "medium")
    MergeTrainMember.create!(merge_train: train, job: first, position: 0)
    MergeTrainMember.create!(merge_train: train, job: second, position: 1)
    owner = described_class.instantiate(kind: "ci_failure", job: first)
    owner.work_unit.update!(state: "running")

    expect {
      described_class.instantiate(kind: "job_bundle", job: second, artifacts: { "merge_train_id" => train.id })
    }.to raise_error(WorkUnits::Launcher::LockConflict, /job:#{first.id}/)

    expect(Workflow.where(trigger_kind: "merge_train").count).to eq(0)
    expect(WorkUnit.where(kind: "job_bundle").count).to eq(0)
  end

  it "preempts active CI repair when a rebase starts for the same job" do
    ci_repair = described_class.instantiate(
      kind: "ci_failure",
      job: job,
      artifacts: { "head_sha" => "head123", "base_sha" => "base123" }
    )
    ci_repair.update!(state: "running")
    ci_repair.work_unit.update!(state: "running")

    rebase = described_class.instantiate(kind: "rebase", job: job, base_branch: "main")

    expect(ci_repair.reload).to be_cancelled
    expect(ci_repair.artifact("cancelled_reason")).to eq(Workflow::SUPERSEDED_BY_REBASE_REASON)
    expect(ci_repair.artifact("preemption_reason")).to eq("superseded_by_rebase")
    expect(ci_repair.work_unit.reload).to have_attributes(
      state: "cancelled",
      preemption_reason: "superseded_by_rebase",
      preempted_by_work_unit: rebase.work_unit
    )
  end

  it "snapshots known ref metadata onto the intent and unit" do
    job.update!(branch_name: "syrus/job-#{job.id}")

    workflow = described_class.instantiate(
      kind: "rebase",
      job: job,
      artifacts: { "delivery_track" => "default" },
      base_branch: "syrus/parent"
    )
    unit = workflow.work_unit
    intent = unit.work_intent

    expect(intent).to have_attributes(
      delivery_track: "default",
      source_repository: repository,
      source_remote_kind: "repository",
      source_ref: job.branch_name,
      target_repository: repository,
      target_remote_kind: "repository",
      target_ref: "syrus/parent"
    )
    expect(unit).to have_attributes(
      delivery_track: "default",
      source_repository: repository,
      source_remote_kind: "repository",
      source_ref: job.branch_name,
      target_repository: repository,
      target_remote_kind: "repository",
      target_ref: "syrus/parent"
    )
  end

  it "can use a specialized template while recording an existing workflow trigger kind" do
    workflow = described_class.instantiate(
      kind: "checkpoint_resume",
      job: job,
      artifacts: { "checkpoint_resume_steps" => %w[prepare summarize] }
    )

    expect(workflow.trigger_kind).to eq("retry")
    expect(workflow.work_unit.kind).to eq("checkpoint_resume")
    expect(workflow.steps.pluck(:kind)).to eq(%w[prepare summarize])
  end

  it "can create and start a workflow through the same funnel" do
    result = described_class.create_and_start!(kind: "manual_visual_review", job: job)

    expect(result.workflow).to be_persisted
    expect(result.workflow.work_unit).to have_attributes(kind: "manual_visual_review")
    expect(result).to be_started
    expect(result.intent).to eq(result.workflow.work_unit.work_intent)
    expect(result.work_unit).to eq(result.workflow.work_unit)
    expect(result.run).to be_queued
    expect(result.run.step).to eq(result.workflow.first_step)
  end

  it "starts an unstarted workflow on an available failover provider during admission" do
    user.update!(
      codex_auth_mode: "api_key",
      codex_api_key: "sk-test",
      agent_provider_failover_policy: {
        "enabled" => true,
        "providers" => %w[codex],
        "causes" => %w[provider_transient],
        "override_explicit_pins" => false
      }
    )
    workflow = described_class.instantiate(kind: "initial", job: job, agent_provider: "claude")
    allow(App::ProviderAvailability).to receive(:for_user).with(user, "claude", now: anything).and_return(
      {
        state: "open",
        open: true,
        retry_after: 10.minutes.from_now.iso8601,
        evidence: { current: { observed_at: 1.minute.ago.iso8601 } }
      }
    )
    allow(App::ProviderAvailability).to receive(:for_user).with(user, "codex", now: anything).and_return(nil)

    result = described_class.start!(workflow)

    expect(result).to be_started
    expect(workflow.reload.agent_provider).to eq("codex")
    expect(result.run.agent_provider).to eq("codex")
    expect(workflow.artifact("provider_failover_decision")).to include(
      "original_provider" => "claude",
      "selected_provider" => "codex",
      "reason" => "provider_unavailable",
      "unavailable" => include(
        "provider" => "claude",
        "state" => "open",
        "retry_after" => kind_of(String),
        "observed_at" => kind_of(String)
      )
    )
  end

  it "runs a callback after workflow creation and before dispatch" do
    state = []
    allow(StepDispatcher).to receive(:start_workflow) do |workflow|
      state << [ :start, workflow.id ]
      workflow.first_step.runs.last
    end

    result = described_class.create_and_start!(
      kind: "manual_visual_review",
      job: job,
      before_start: ->(workflow) { state << [ :before_start, workflow.id ] }
    )

    expect(result.workflow).to be_persisted
    expect(state).to eq([
      [ :before_start, result.workflow.id ],
      [ :start, result.workflow.id ]
    ])
  end

  it "can start an existing workflow through the launcher boundary" do
    workflow = described_class.instantiate(kind: "manual_visual_review", job: job)

    result = described_class.start!(workflow)

    expect(result.workflow).to eq(workflow)
    expect(result).to be_started
    expect(result.run).to be_queued
    expect(result.run.step).to eq(workflow.first_step)
  end

  it "repairs approved single-job landing work to landing before starting" do
    landing_job = Job.create!(
      user: user,
      owner_user: user,
      repository: repository,
      state: "implemented",
      issue_number: nil,
      external_pr_number: 2904,
      kind: "external_pr"
    )
    landing_job.update_columns(state: "approved", approved_at: 1.minute.ago, approved_via: "operator")
    workflow = described_class.instantiate(kind: "external_pr_merge", job: landing_job)

    result = described_class.start!(workflow)

    expect(result).to be_started
    expect(landing_job.reload).to be_landing
  end

  it "lets the work unit scheduler block a start before the first Run is created" do
    workflow = described_class.instantiate(kind: "manual_visual_review", job: job)
    workflow.work_unit.request_pause!

    expect {
      @result = described_class.start!(workflow)
    }.not_to change { Run.count }

    expect(@result).to be_blocked
    expect(@result.workflow).to eq(workflow)
    expect(@result.run).to be_nil
    expect(@result.reason).to eq("manual_pause")
    expect(@result.work_unit.reload).to have_attributes(state: "blocked", blocked_reason: "manual_pause")
  end

  it "schedules a recheck when a runtime gate blocks the launch" do
    workflow = described_class.instantiate(kind: "manual_visual_review", job: job)
    retry_at = 12.minutes.from_now
    gate_result = WorkUnits::GateResult.block(
      reason: WorkUnits::Gates::ProviderAvailability::REASON,
      retry_at: retry_at,
      details: { "provider" => "codex" }
    )
    allow(WorkUnits::Scheduler).to receive(:evaluate!).with(workflow.work_unit).and_return(gate_result)

    expect {
      @result = described_class.start!(workflow)
    }.not_to change { Run.count }

    expect(@result).to be_blocked
    expect(enqueued_jobs.select { |entry| entry[:job] == WorkflowPhaseAdmissionJob }.last[:at]).to be_within(2.seconds).of(retry_at.to_f)
  end

  it "does not schedule automatic rechecks for manual pauses" do
    workflow = described_class.instantiate(kind: "manual_visual_review", job: job)
    gate_result = WorkUnits::GateResult.block(
      reason: WorkUnits::Gates::ManualPause::REASON,
      details: { "pause_requested" => true }
    )
    allow(WorkUnits::Scheduler).to receive(:evaluate!).with(workflow.work_unit).and_return(gate_result)

    described_class.start!(workflow)

    expect(enqueued_jobs.map { |entry| entry[:job] }).not_to include(WorkflowPhaseAdmissionJob)
  end

  it "snapshots merge train members from the merge train artifact" do
    epic = Factories.epic(user: user, repository: repository)
    first = Factories.job_record(user: user, repository: repository, epic: epic)
    second = Factories.job_record(user: user, repository: repository, epic: epic)
    train = MergeTrain.create!(epic: epic, repository: repository, base_branch: "main")
    MergeTrainMember.create!(merge_train: train, job: first, position: 0)
    MergeTrainMember.create!(merge_train: train, job: second, position: 1)

    workflow = described_class.instantiate(
      kind: "merge_train",
      job: second,
      artifacts: { "merge_train_id" => train.id }
    )

    expect(workflow.work_unit.work_unit_members.order(:id).map { |member| [ member.job_id, member.role ] }).to eq(
      [[ first.id, "primary" ], [ second.id, "member" ]]
    )
    expect(workflow.work_unit.work_unit_locks.pluck(:lock_key)).to contain_exactly(
      "epic:#{epic.id}",
      "job:#{first.id}",
      "job:#{second.id}",
      "landing:repository:#{repository.id}"
    )
  end

  it "uses maintenance-scoped locks for stack rebase workflows" do
    epic = Factories.epic(user: user, repository: repository)
    parent = Factories.job_record(user: user, repository: repository, epic: epic)
    child = Factories.job_record(user: user, repository: repository, epic: epic, parent_job: parent)

    workflow = described_class.instantiate(kind: "stack_rebase", job: child, base_branch: parent.branch_name || "main")

    expect(workflow.work_unit.work_unit_locks.pluck(:lock_key)).to contain_exactly(
      "maintenance:rebase:job:#{child.id}",
      "maintenance:stack_rebase:epic:#{epic.id}"
    )
  end
end
