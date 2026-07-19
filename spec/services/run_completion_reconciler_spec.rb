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
