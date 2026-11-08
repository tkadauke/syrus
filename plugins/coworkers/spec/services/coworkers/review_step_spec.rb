require "rails_helper"

RSpec.describe Coworkers::ReviewStep do
  let(:job) { Factories.job(issue_title: "Review the rollout", issue_body: "Check organizational fit.") }
  let(:workflow) { job.latest_workflow }
  let(:implement_step) { workflow.steps.find_by!(kind: "implement") }
  let(:review_step) do
    Step.create!(workflow: workflow, kind: "coworker_review", position: 99, iteration: 1,
                 loop_id: "coworker-loop", details: { "reviewer_target" => { "type" => "coworker", "reference" => "7" } })
  end
  let(:run) { review_step.runs.create!(job: job, trigger_kind: "initial") }
  let(:handler) { described_class.new(run) }
  let(:review_config) do
    Coworkers::RepositoryConfiguration::Config.new(enabled: true, rounds: 2, criteria: [ "Check rollout ownership" ], required: false)
  end

  before do
    implement_step.update!(state: "succeeded")
    implement_step.runs.create!(job: job, trigger_kind: "initial", state: "succeeded",
                                step_agent_diff: "diff --git a/app.rb b/app.rb\n+change\n", base_sha: "base-sha")
    workspace = instance_double(WorkflowWorkspace, setup: true, path: Pathname.new("/tmp/workspace"), base_ref: "origin/main")
    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:review_config).and_return(review_config)
    allow(ReviewEvidence::Capture).to receive(:call)
    # The Coworkers context contributor needs real coworker records; this spec
    # covers the step's own behavior.
    allow(ReviewContextContributions).to receive(:prepare).and_raise(ReviewContextContributions::Unavailable)
    allow(Coworkers::ReviewProjects).to receive(:call).and_return(
      Coworkers::ReviewProjects::Result.new(projects: [
        Coworkers::ReviewProjects::Project.new(
          id: "repo", label: "Repository", path: "", owner_config_path: ".syrus.yml",
          criteria: [ "Check rollout ownership" ]
        )
      ])
    )
  end

  it "hard-fails before invocation without a pinned reviewer" do
    review_step.update!(details: {})

    expect { handler.call }.to raise_error(ReviewerTargets::TargetRequired)
  end

  it "uses dedicated criteria, submission tool, and iteration artifact" do
    evidence = instance_double(ReviewEvidence, id: 42, state: "submitted", reviewer: nil)
    allow(run).to receive(:review_evidence).and_return(evidence)
    allow(run).to receive(:reload).and_return(run)
    allow(ReviewEvidence::VerifySubmission).to receive(:call!).and_return(evidence)
    expect(handler).to receive(:run_agent) do |prompt:, required_mcp_tools:, **|
      expect(prompt).to include("accountable coworker", "Check rollout ownership")
      expect(required_mcp_tools).to eq(%w[submit_coworker_review])
      workflow.set_artifact!("coworker_review_iterations", [
        { "iteration" => 1, "review_evidence_id" => 42, "critique" => "Operationally sound.", "verdict" => "approved" }
      ])
      review_step.update!(details: review_step.details.to_h.merge(
        "review_persistence_receipt" => { "key" => "review/42", "version" => "1" }
      ))
    end

    handler.call

    expect(workflow.reload.artifact("coworker_review_iterations").sole).to include("verdict" => "approved")
  end

  it "skips an optional gate on an eligible transient execution failure" do
    allow(handler).to receive(:run_agent).and_raise(StandardError, "prompt is too long")

    expect { handler.call }.to raise_error(Steps::Base::StepSkipped, /prompt is too long/)
    expect(workflow.reload.artifact("coworker_review_iterations").sole).to include(
      "verdict" => "skipped", "skipped" => true
    )
  end

  it "fails a required gate on the same transient execution failure" do
    allow(handler).to receive(:review_config).and_return(review_config.with(required: true))
    allow(handler).to receive(:run_agent).and_raise(StandardError, "prompt is too long")

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /coworker_review review could not execute/)
    expect(workflow.reload.workflow_warnings).to be_empty
  end

  it "does not advance when submitted coworker evidence becomes stale" do
    evidence = instance_double(ReviewEvidence, id: 42, state: "submitted", reviewer: nil)
    allow(run).to receive(:review_evidence).and_return(evidence)
    allow(run).to receive(:reload).and_return(run)
    allow(handler).to receive(:run_agent) do
      workflow.set_artifact!("coworker_review_iterations", [
        { "iteration" => 1, "review_evidence_id" => 42, "critique" => "OK", "verdict" => "approved" }
      ])
      allow(evidence).to receive(:state).and_return("stale")
      allow(evidence).to receive(:terminal_failure_code).and_return("review_evidence_stale")
      allow(evidence).to receive(:terminal_failure_details).and_return({ "reason" => "head changed" })
    end

    expect { handler.call }.to raise_error(Steps::AdversarialReview::EvidenceStale)
  end

  it "requires the contributed post-verdict update before succeeding" do
    evidence = instance_double(ReviewEvidence, id: 42, state: "submitted", reviewer: nil)
    allow(run).to receive(:review_evidence).and_return(evidence)
    allow(run).to receive(:reload).and_return(run)
    allow(ReviewEvidence::VerifySubmission).to receive(:call!).and_return(evidence)
    allow(handler).to receive(:run_agent) do
      workflow.set_artifact!("coworker_review_iterations", [
        { "iteration" => 1, "review_evidence_id" => 42, "critique" => "Needs repair.", "verdict" => "needs_work" }
      ])
    end

    expect { handler.call }.to raise_error(Coworkers::ReviewStep::MemoryPersistenceFailed, /post-verdict update was not persisted/)
  end
end
