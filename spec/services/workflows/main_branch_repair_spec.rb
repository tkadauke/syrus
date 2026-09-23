require "rails_helper"

RSpec.describe Workflows::MainBranchRepair do
  let(:user) { Factories.user }
  let(:repository) do
    Factories.repository(user: user).tap do |r|
      r.update!(
        grader_health: "broken",
        last_health_checked_sha: "abc123def456"
      )
    end
  end
  let(:job) do
    Job.create!(
      user: user,
      repository: repository,
      kind: "direct",
      system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
      issue_title: Job::MAIN_BRANCH_REPAIR_TITLE,
      issue_number: nil
    )
  end

  describe "chain" do
    it "starts with prepare before preflight grader steps" do
      workflow = described_class.instantiate(job: job)

      kinds = workflow.steps.order(:position).pluck(:kind)
      prepare_idx  = kinds.index("prepare")
      preflight_idx = kinds.index("preflight_grader_fanout")
      expect(prepare_idx).to be < preflight_idx
    end

    it "runs preflight grader fanout and collect before implement" do
      workflow = described_class.instantiate(job: job)

      kinds = workflow.steps.order(:position).pluck(:kind)
      expect(kinds.first(3)).to eq(%w[ prepare preflight_grader_fanout preflight_grader_collect ])
    end

    it "includes prepare followed by preflight graders and then the grade retry loop" do
      workflow = described_class.instantiate(job: job)

      kinds = workflow.steps.order(:position).pluck(:kind)
      expect(kinds).to include("prepare", "preflight_grader_fanout", "implement", "grader_fanout", "grader_collect")
    end

    it "ends with summarize, test_plan, pr_open" do
      workflow = described_class.instantiate(job: job)

      kinds = workflow.steps.order(:position).pluck(:kind)
      expect(kinds.last(3)).to eq(%w[ summarize test_plan pr_open ])
    end

    it "sets trigger_kind to main_branch_repair" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.trigger_kind).to eq("main_branch_repair")
    end

    it "uses the runs queue" do
      expect(described_class.queue_name).to eq(:runs)
    end

    it "honors repository-level prepare disablement" do
      repository.update!(prepare_enabled: false)

      workflow = described_class.instantiate(job: job)

      kinds = workflow.steps.order(:position).pluck(:kind)
      expect(kinds).not_to include("prepare")
      expect(workflow.artifact("prepare_skipped_reason")).to eq("repository_configuration")
    end
  end

  describe ".after_success" do
    let(:workflow) { described_class.instantiate(job: job) }

    context "when preflight_passed artifact is set" do
      before { workflow.set_artifact!("preflight_passed", true) }

      it "updates grader_health to healthy" do
        described_class.after_success(workflow)

        expect(repository.reload.grader_health).to eq("healthy")
      end

      it "updates ci_health to healthy since preflight now re-runs the ci-phase graders" do
        repository.update!(ci_health: "broken")

        described_class.after_success(workflow)

        expect(repository.reload.ci_health).to eq("healthy")
      end

      it "records last_graded_sha for the repaired main SHA" do
        described_class.after_success(workflow)

        expect(repository.reload.last_graded_sha).to eq("abc123def456")
      end

      it "records last_ci_evaluated_sha for the repaired main SHA" do
        described_class.after_success(workflow)

        expect(repository.reload.last_ci_evaluated_sha).to eq("abc123def456")
      end

      it "records a grader health check linked to the workflow" do
        described_class.after_success(workflow)

        check = MainBranchHealthCheck.last
        expect(check.workflow).to eq(workflow)
        expect(check.grader_health).to eq("healthy")
        expect(check.ci_health).to eq("healthy")
      end

      it "closes the anchor job" do
        described_class.after_success(workflow)

        expect(job.reload.state).to eq("closed")
      end

      it "sets closure_reason to preflight_passed" do
        described_class.after_success(workflow)

        expect(job.reload.closure_reason).to eq("preflight_passed")
      end

      it "honors a preflight artifact written by a different workflow instance" do
        stale_workflow = Workflow.find(workflow.id)
        stale_workflow.artifacts = {}

        described_class.after_success(stale_workflow)

        expect(job.reload).to be_closed
        expect(job.closure_reason).to eq("preflight_passed")
      end

      it "calls MainHealthChangedService when grader health transitions to healthy" do
        expect(MainHealthChangedService).to receive(:on_health_change!).with(kind_of(Repository))

        described_class.after_success(workflow)
      end

      it "does not call MainHealthChangedService when grader_health was already healthy and CI is healthy" do
        repository.update!(grader_health: "healthy", ci_health: "healthy")

        expect(MainHealthChangedService).not_to receive(:on_health_change!)

        described_class.after_success(workflow)
      end

      it "calls MainHealthChangedService when graders recover and landing was paused" do
        repository.update!(landing_paused: true, ci_health: "not_configured")

        expect(MainHealthChangedService).to receive(:on_health_change!).with(kind_of(Repository))

        described_class.after_success(workflow)
      end

      it "calls MainHealthChangedService when CI was unknown, since preflight passing now resolves ci_health too" do
        repository.update!(grader_health: "unknown", ci_health: "unknown")

        expect(MainHealthChangedService).to receive(:on_health_change!).with(kind_of(Repository))

        described_class.after_success(workflow)
      end
    end

    context "when preflight_passed artifact is not set (full repair path)" do
      it "does not modify grader_health" do
        original_health = repository.grader_health

        described_class.after_success(workflow)

        expect(repository.reload.grader_health).to eq(original_health)
      end

      it "does not close the anchor job" do
        described_class.after_success(workflow)

        expect(job.reload.state).not_to eq("closed")
      end

      it "does not call MainHealthChangedService" do
        expect(MainHealthChangedService).not_to receive(:on_health_change!)

        described_class.after_success(workflow)
      end
    end
  end

  describe "preflight-pass path (regression: uncleared_retry_until_barrier_after_success)" do
    it "runs PreflightGraderCollect for real, walks the dispatcher forward, and reaches after_success instead of hard-failing on the skipped grade-loop barrier" do
      workflow = described_class.instantiate(job: job)
      workflow.start!
      workflow.save!

      prepare_step = workflow.steps.find_by!(kind: "prepare")
      fanout_step  = workflow.steps.find_by!(kind: "preflight_grader_fanout")
      collect_step = workflow.steps.find_by!(kind: "preflight_grader_collect")

      prepare_step.update_columns(state: "succeeded", started_at: 2.minutes.ago, finished_at: 90.seconds.ago)
      fanout_step.update_columns(state: "succeeded", started_at: 90.seconds.ago, finished_at: 60.seconds.ago)

      run = collect_step.runs.create!(
        job: job,
        trigger_kind: workflow.trigger_kind,
        state: "running",
        iteration: collect_step.iteration
      )
      Steps::PreflightGraderCollect.new(run).call

      run.update_columns(state: "succeeded", finished_at: Time.current)
      collect_step.update_columns(state: "succeeded", started_at: 60.seconds.ago, finished_at: Time.current)

      # The grade loop's grader_collect step is a retry_until barrier
      # (Step::Kind#fail_policy == :loop_iteration); PreflightGraderCollect's
      # cancel_downstream! must have marked it retry_until_barrier_superseded
      # so it doesn't read as "uncleared" once skipped.
      grade_loop_barrier = workflow.steps.find_by!(kind: "grader_collect")
      expect(grade_loop_barrier).to be_skipped
      expect(grade_loop_barrier.retry_until_barrier_superseded?).to be true

      StepDispatcher.advance_from(collect_step)

      workflow.reload
      expect(workflow).to be_succeeded
      expect(workflow.failure_reason).to be_nil
      expect(job.reload.state).to eq("closed")
      expect(job.reload.closure_reason).to eq("preflight_passed")
      expect(repository.reload.grader_health).to eq("healthy")
    end
  end

  describe "Job#create_initial_run routing" do
    before { allow(StepDispatcher).to receive(:start_workflow) }

    it "uses MainBranchRepair for main_branch_repair jobs" do
      expect(Workflows::MainBranchRepair).to receive(:instantiate).and_call_original

      job.advance_after_triage!
    end

    it "creates a workflow with trigger_kind main_branch_repair" do
      allow(Workflows::MainBranchRepair).to receive(:instantiate).and_call_original

      job.advance_after_triage!

      expect(job.workflows.last.trigger_kind).to eq("main_branch_repair")
    end
  end
end
