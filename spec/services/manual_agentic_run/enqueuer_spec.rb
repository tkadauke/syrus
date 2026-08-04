require "rails_helper"

RSpec.describe ManualAgenticRun::Enqueuer do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) do
    Factories.job_record(
      user: user,
      repository: repository,
      state: "implemented",
      branch_name: "syrus/direct-2561",
      pr_number: 2561
    )
  end

  it "starts an audited manual agentic workflow on the current PR branch" do
    allow(StepDispatcher).to receive(:start_workflow) do |workflow|
      workflow.first_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
    end

    result = described_class.call(
      job: job,
      base: "current_pr_branch",
      instructions: "Inspect the failing rspec check and update only tests.",
      reason: "Operator requested focused repair.",
      push: true
    )

    expect(result.workflow).to have_attributes(job: job, trigger_kind: "manual_agentic_run")
    expect(result.run).to be_present
    expect(result.workflow.artifact("manual_agentic_run_base")).to eq("current_pr_branch")
    expect(result.workflow.artifact("manual_agentic_run_push")).to be(true)
    expect(result.workflow.artifact("manual_agentic_run_instructions")).to eq("Inspect the failing rspec check and update only tests.")
    expect(result.workflow.steps.pluck(:kind)).to include("prepare", "manual_agentic_run", "grader_fanout", "grader_collect", "summarize_amend", "push")
    expect(StepDispatcher).to have_received(:start_workflow).with(result.workflow)
  end

  it "rejects pushing from a fresh checkout" do
    expect {
      described_class.call(
        job: job,
        base: "fresh_checkout",
        instructions: "Diagnose branch divergence.",
        reason: "Operator requested diagnosis.",
        push: true
      )
    }.to raise_error(ArgumentError, /fresh_checkout cannot push/)
  end

  it "returns a failed-workspace base when the retained workspace exists" do
    failed = Workflow.create!(job: job, trigger_kind: "manual", state: "failed", agent_provider: job.agent_provider)
    path = WorkflowWorkspace.path_for(failed)
    FileUtils.mkdir_p(path)

    result = ManualAgenticRun::FailedWorkflowWorkspace.new(
      job: job,
      payload: { "failed_workflow_id" => failed.id }
    ).resolve

    expect(result).to be_success
    expect(result.artifacts).to include(
      "manual_agentic_run_base" => "failed_workflow_workspace",
      "failed_workflow_id" => failed.id,
      "local_source_path" => path.to_s,
      "local_source_branch" => job.branch_name
    )
  ensure
    FileUtils.rm_rf(path) if path
  end

  it "returns a structured base result when the failed workspace is unavailable" do
    result = ManualAgenticRun::FailedWorkflowWorkspace.new(
      job: job,
      payload: {}
    ).resolve

    expect(result).not_to be_success
    expect(result.error).to eq("failed_workflow_workspace_unavailable")
    expect(result.valid_bases).to eq(%w[current_pr_branch fresh_checkout])
  end
end
