require "rails_helper"

RSpec.describe RunCompletionReconciler do
  let(:job) { Factories.job }
  let(:workflow) { job.latest_workflow }

  def make_pr_open_run
    step = Step.create!(workflow: workflow, kind: "pr_open", position: 99)
    run = step.runs.create!(job: job, trigger_kind: "initial", agent_provider: job.agent_provider)
    step.update_columns(state: "running", started_at: Time.current)
    run.update_columns(state: "running", started_at: Time.current)
    workflow.update_columns(state: "running", started_at: Time.current)
    run
  end

  describe "#call" do
    it "returns unreconciled when the run is not in running state" do
      run = job.initial_run
      run.update_columns(state: "queued")

      result = described_class.call(run)

      expect(result).not_to be_reconciled
    end

    it "returns unreconciled when step kind is not pr_open" do
      run = job.initial_run
      step = run.step
      step.update_columns(state: "running")
      run.update_columns(state: "running")
      workflow.update_columns(state: "running")

      result = described_class.call(run)

      expect(result).not_to be_reconciled
    end

    it "recovers a deterministic step that returned successfully after a terminal race" do
      workflow.steps.destroy_all
      step = Step.create!(workflow: workflow, kind: "grader", position: 1)
      run = step.runs.create!(job: job, trigger_kind: "initial", agent_provider: job.agent_provider)
      workflow.update_columns(state: "running", started_at: 10.minutes.ago)
      step.update_columns(state: "failed", started_at: 5.minutes.ago, finished_at: 1.minute.ago)
      run.update_columns(state: "failed", started_at: 5.minutes.ago, finished_at: 1.minute.ago)

      allow(StepDispatcher).to receive(:advance_from)

      result = described_class.call(run, allow_terminal_recovery: true)

      expect(result).to be_reconciled
      expect(result.reason).to eq("grader: handler returned successfully after terminal race")
      expect(run.reload).to be_succeeded
      expect(step.reload).to be_succeeded
      expect(workflow.reload).to be_succeeded
      expect(StepDispatcher).to have_received(:advance_from).with(step)
    end

    it "does not rewrite a failed grader after its collector has started" do
      workflow.steps.destroy_all
      loop_id = SecureRandom.uuid
      step = Step.create!(workflow: workflow, kind: "grader", position: 1, loop_id: loop_id, iteration: 2)
      collect = Step.create!(workflow: workflow, kind: "grader_collect", position: 2, loop_id: loop_id, iteration: 2)
      run = step.runs.create!(job: job, trigger_kind: "initial", agent_provider: job.agent_provider)
      workflow.update_columns(state: "running", started_at: 10.minutes.ago)
      step.update_columns(state: "failed", started_at: 5.minutes.ago, finished_at: 1.minute.ago)
      run.update_columns(state: "failed", started_at: 5.minutes.ago, finished_at: 1.minute.ago)
      collect.update_columns(state: "running", started_at: 30.seconds.ago)

      result = described_class.call(run, allow_terminal_recovery: true)

      expect(result).not_to be_reconciled
      expect(result.reason).to eq("grader is not eligible for terminal recovery")
      expect(run.reload).to be_failed
      expect(step.reload).to be_failed
    end

    it "does not recover non-deterministic terminal races after the workflow has already failed" do
      workflow.steps.destroy_all
      step = Step.create!(workflow: workflow, kind: "implement", position: 1)
      run = step.runs.create!(job: job, trigger_kind: "initial", agent_provider: job.agent_provider)
      workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
      step.update_columns(state: "failed", started_at: 5.minutes.ago, finished_at: 1.minute.ago)
      run.update_columns(state: "failed", started_at: 5.minutes.ago, finished_at: 1.minute.ago)

      result = described_class.call(run, allow_terminal_recovery: true)

      expect(result).not_to be_reconciled
      expect(run.reload).to be_failed
      expect(step.reload).to be_failed
      expect(workflow.reload).to be_failed
    end

    it "reopens a failed workflow when deterministic fanout returned successfully after a terminal race" do
      workflow.steps.destroy_all
      fanout = Step.create!(workflow: workflow, kind: "grader_fanout", position: 1)
      collect = Step.create!(workflow: workflow, kind: "grader_collect", position: 2)
      fanout.update!(next_step: collect)
      run = fanout.runs.create!(job: job, trigger_kind: "initial", agent_provider: job.agent_provider)
      workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
      fanout.update_columns(state: "failed", started_at: 5.minutes.ago, finished_at: 1.minute.ago)
      run.update_columns(state: "failed", started_at: 5.minutes.ago, finished_at: 1.minute.ago)
      allow(StepDispatcher).to receive(:advance_from)

      result = described_class.call(run, allow_terminal_recovery: true)

      expect(result).to be_reconciled
      expect(result.reason).to eq("grader_fanout: handler returned successfully after terminal race")
      expect(run.reload).to be_succeeded
      expect(fanout.reload).to be_succeeded
      expect(workflow.reload).not_to be_failed
      expect(workflow.failure_reason).to be_nil
      expect(workflow.artifact("terminal_success_race_recovered_run_id")).to eq(run.id)
      expect(StepDispatcher).to have_received(:advance_from).with(fanout)
    end

    it "recovers deterministic fanout when the step was already reset out of running" do
      workflow.steps.destroy_all
      fanout = Step.create!(workflow: workflow, kind: "grader_fanout", position: 1)
      collect = Step.create!(workflow: workflow, kind: "grader_collect", position: 2)
      fanout.update!(next_step: collect)
      run = fanout.runs.create!(job: job, trigger_kind: "initial", agent_provider: job.agent_provider)
      workflow.update_columns(state: "running", started_at: 10.minutes.ago)
      run.update_columns(state: "failed", started_at: 5.minutes.ago, finished_at: 1.minute.ago)
      allow(StepDispatcher).to receive(:advance_from)

      %w[queued succeeded].each do |state|
        fanout.update_columns(state: state, started_at: 5.minutes.ago, finished_at: (state == "succeeded" ? 1.minute.ago : nil))
        run.update_columns(state: "failed", finished_at: 1.minute.ago)

        result = described_class.call(run, allow_terminal_recovery: true)

        expect(result).to be_reconciled
        expect(result.reason).to eq("grader_fanout: handler returned successfully after terminal race")
        expect(run.reload).to be_succeeded
        expect(fanout.reload).to be_succeeded
        expect(workflow.reload).to be_running
      end
    end

    it "revives grader steps cancelled by terminal cleanup when fanout recovers after a terminal race" do
      workflow.steps.destroy_all
      loop_id = SecureRandom.uuid
      fanout = Step.create!(workflow: workflow, kind: "grader_fanout", position: 1, loop_id: loop_id)
      grader = Step.create!(workflow: workflow, kind: "grader", position: 2, loop_id: loop_id)
      collect = Step.create!(workflow: workflow, kind: "grader_collect", position: 3, loop_id: loop_id)
      fanout.update!(next_step: grader)
      grader.update!(next_step: collect)
      run = fanout.runs.create!(job: job, trigger_kind: "initial", agent_provider: job.agent_provider)

      workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
      fanout.update_columns(state: "failed", started_at: 5.minutes.ago, finished_at: 1.minute.ago)
      run.update_columns(state: "failed", started_at: 5.minutes.ago, finished_at: 1.minute.ago)
      [ grader, collect ].each do |downstream|
        downstream.update_columns(
          state: "cancelled",
          cancellation_reason: "cancel_terminal_workflow_active_descendants",
          details: {
            "cancelled_by" => "terminal_workflow_cleanup",
            "cancelled_reason" => "cancel_terminal_workflow_active_descendants"
          },
          started_at: nil,
          finished_at: 30.seconds.ago
        )
      end
      allow(StepDispatcher).to receive(:advance_from)

      result = described_class.call(run, allow_terminal_recovery: true)

      expect(result).to be_reconciled
      expect(run.reload).to be_succeeded
      expect(fanout.reload).to be_succeeded
      expect(workflow.reload).to be_running
      expect(grader.reload).to have_attributes(state: "queued", cancellation_reason: nil, started_at: nil, finished_at: nil)
      expect(collect.reload).to have_attributes(state: "queued", cancellation_reason: nil, started_at: nil, finished_at: nil)
      expect(grader.details).not_to include("cancelled_by")
      expect(collect.details).not_to include("cancelled_by")
      expect(StepDispatcher).to have_received(:advance_from).with(fanout)
    end

    context "with a running pr_open step" do
      it "returns unreconciled when no matching log entries exist" do
        run = make_pr_open_run
        JobLog.append!(run: run, chunk: "pr_open: checking PR status")

        result = described_class.call(run)

        expect(result).not_to be_reconciled
      end

      it "reconciles when the log contains a 'pr_open: opened PR' entry" do
        run = make_pr_open_run
        job.update!(pr_number: nil)
        JobLog.append!(run: run, chunk: "pr_open: opened PR #42")

        allow(StepDispatcher).to receive(:advance_from)

        result = described_class.call(run)

        expect(result).to be_reconciled
        expect(result.reason).to include("PR #42")
        expect(run.reload.state).to eq("succeeded")
        expect(run.step.reload.state).to eq("succeeded")
        expect(job.reload.pr_number).to eq(42)
      end

      it "reconciles when the log contains a 'pr_open: branch pushed for existing PR' entry" do
        run = make_pr_open_run
        job.update!(pr_number: 99)
        JobLog.append!(run: run, chunk: "pr_open: branch pushed for existing PR #99")

        allow(StepDispatcher).to receive(:advance_from)

        result = described_class.call(run)

        expect(result).to be_reconciled
        expect(result.reason).to include("PR #99")
        expect(run.reload.state).to eq("succeeded")
      end

      it "returns unreconciled when the log's PR number does not match the job's pr_number" do
        run = make_pr_open_run
        job.update!(pr_number: 55)
        JobLog.append!(run: run, chunk: "pr_open: opened PR #99")

        result = described_class.call(run)

        expect(result).not_to be_reconciled
        expect(run.reload.state).to eq("running")
      end

      it "advances the workflow after reconciling" do
        run = make_pr_open_run
        job.update!(pr_number: nil)
        JobLog.append!(run: run, chunk: "pr_open: opened PR #7")

        advance_called = false
        allow(StepDispatcher).to receive(:advance_from) { advance_called = true }

        described_class.call(run)

        expect(advance_called).to be true
      end

      it "bounds pr_open log recovery to recent transcript chunks" do
        run = make_pr_open_run
        job.update!(pr_number: nil)
        JobLog.append!(run: run, chunk: "pr_open: opened PR #7")
        described_class::PR_OPEN_RECOVERY_LOG_LIMIT.times do |index|
          JobLog.append!(run: run, chunk: "later chunk #{index}")
        end

        result = described_class.call(run)

        expect(result).not_to be_reconciled
        expect(run.reload.state).to eq("running")
        expect(job.reload.pr_number).to be_nil
      end

      it "force-recovers terminal pr_open records when the log proves the PR opened" do
        run = make_pr_open_run
        job.update!(pr_number: nil)
        JobLog.append!(run: run, chunk: "pr_open: opened PR #7")
        run.update_columns(state: "failed", finished_at: Time.current)
        run.step.update_columns(state: "failed", finished_at: Time.current)
        workflow.update_columns(state: "failed", finished_at: Time.current)

        result = described_class.call(run, allow_terminal_recovery: true)

        expect(result).to be_reconciled
        expect(result.reason).to eq("pr_open already opened PR #7")
        expect(run.reload).to be_succeeded
        expect(run.step.reload).to be_succeeded
        expect(workflow.reload).to be_succeeded
        expect(job.reload.pr_number).to eq(7)
      end

      it "does not reconcile a workflow to success behind an uncleared retry barrier" do
        workflow.steps.destroy_all
        loop_id = SecureRandom.uuid
        Step.create!(
          workflow: workflow,
          kind: "grader_collect",
          position: 10,
          loop_id: loop_id,
          iteration: 1,
          state: "failed",
          started_at: 3.minutes.ago,
          finished_at: 2.minutes.ago
        )
        run = make_pr_open_run
        job.update!(pr_number: nil)
        JobLog.append!(run: run, chunk: "pr_open: opened PR #7")
        allow(StepDispatcher).to receive(:advance_from)

        result = described_class.call(run)

        expect(result).to be_reconciled
        expect(run.reload).to be_succeeded
        expect(run.step.reload).to be_succeeded
        expect(workflow.reload).to be_failed
        expect(workflow.failure_reason).to eq("uncleared_retry_until_barrier_after_success")
      end
    end

    context "with a running auto_merge step" do
      let(:client) { instance_double(GithubClient) }

      def make_auto_merge_run
        step = Step.create!(workflow: workflow, kind: "auto_merge", position: 99)
        run = step.runs.create!(job: job, trigger_kind: "auto_merge", agent_provider: job.agent_provider)
        step.update_columns(state: "running", started_at: Time.current)
        run.update_columns(state: "running", started_at: Time.current)
        workflow.update_columns(state: "running", started_at: Time.current)
        run
      end

      it "reconciles when GitHub reports the PR as merged" do
        job.update!(pr_number: 77)
        run = make_auto_merge_run
        allow(GithubClient).to receive(:for).and_return(client)
        allow(client).to receive(:pull_request).and_return({ merged: true })
        allow(StepDispatcher).to receive(:advance_from)

        result = described_class.call(run)

        expect(result).to be_reconciled
        expect(result.reason).to include("PR #77")
        expect(run.reload.state).to eq("succeeded")
        expect(run.step.reload.state).to eq("succeeded")
      end

      it "returns unreconciled when GitHub reports the PR as not merged" do
        job.update!(pr_number: 77)
        run = make_auto_merge_run
        allow(GithubClient).to receive(:for).and_return(client)
        allow(client).to receive(:pull_request).and_return({ merged: false })

        result = described_class.call(run)

        expect(result).not_to be_reconciled
        expect(run.reload.state).to eq("running")
      end

      it "returns unreconciled when GitHub raises Octokit::NotFound" do
        job.update!(pr_number: 77)
        run = make_auto_merge_run
        allow(GithubClient).to receive(:for).and_return(client)
        allow(client).to receive(:pull_request).and_raise(Octokit::NotFound.new)

        result = described_class.call(run)

        expect(result).not_to be_reconciled
        expect(run.reload.state).to eq("running")
      end

      it "returns unreconciled when the job has no pr_number" do
        job.update_column(:pr_number, nil)
        run = make_auto_merge_run

        result = described_class.call(run)

        expect(result).not_to be_reconciled
      end
    end

    context "with a running merge_train_land step" do
      let(:client) { instance_double(GithubClient) }

      def make_merge_train_land_run(kind: "merge_train_land")
        step = Step.create!(workflow: workflow, kind: kind, position: 99)
        run = step.runs.create!(job: job, trigger_kind: "merge_train", agent_provider: job.agent_provider)
        step.update_columns(state: "running", started_at: Time.current)
        run.update_columns(state: "running", started_at: Time.current)
        workflow.update_columns(state: "running", started_at: Time.current)
        run
      end

      it "reconciles when GitHub reports the integration PR as merged" do
        workflow.set_artifact!(Steps::MergeTrainLand::INTEGRATION_PR_ARTIFACT, 55)
        run = make_merge_train_land_run
        allow(GithubClient).to receive(:for).and_return(client)
        allow(client).to receive(:pull_request).and_return({ merged: true })
        allow(StepDispatcher).to receive(:advance_from)

        result = described_class.call(run)

        expect(result).to be_reconciled
        expect(result.reason).to include("PR #55")
        expect(run.reload.state).to eq("succeeded")
        expect(run.step.reload.state).to eq("succeeded")
      end

      it "returns unreconciled when GitHub reports the integration PR as not merged" do
        workflow.set_artifact!(Steps::MergeTrainLand::INTEGRATION_PR_ARTIFACT, 55)
        run = make_merge_train_land_run
        allow(GithubClient).to receive(:for).and_return(client)
        allow(client).to receive(:pull_request).and_return({ merged: false })

        result = described_class.call(run)

        expect(result).not_to be_reconciled
        expect(run.reload.state).to eq("running")
      end

      it "returns unreconciled when GitHub raises Octokit::NotFound" do
        workflow.set_artifact!(Steps::MergeTrainLand::INTEGRATION_PR_ARTIFACT, 55)
        run = make_merge_train_land_run
        allow(GithubClient).to receive(:for).and_return(client)
        allow(client).to receive(:pull_request).and_raise(Octokit::NotFound.new)

        result = described_class.call(run)

        expect(result).not_to be_reconciled
        expect(run.reload.state).to eq("running")
      end

      it "returns unreconciled when the workflow has no integration PR artifact" do
        run = make_merge_train_land_run

        result = described_class.call(run)

        expect(result).not_to be_reconciled
      end

      it "also reconciles for merge_train_land_after_rebase" do
        workflow.set_artifact!(Steps::MergeTrainLand::INTEGRATION_PR_ARTIFACT, 55)
        run = make_merge_train_land_run(kind: "merge_train_land_after_rebase")
        allow(GithubClient).to receive(:for).and_return(client)
        allow(client).to receive(:pull_request).and_return({ merged: true })
        allow(StepDispatcher).to receive(:advance_from)

        result = described_class.call(run)

        expect(result).to be_reconciled
        expect(run.reload.state).to eq("succeeded")
      end
    end
  end
end
