require "rails_helper"

RSpec.describe Steps::CoworkerReview do
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
    SyrusYml::CoworkerReviewConfig.new(enabled: true, rounds: 2, criteria: [ "Check rollout ownership" ], required: false)
  end

  before do
    implement_step.update!(state: "succeeded")
    implement_step.runs.create!(job: job, trigger_kind: "initial", state: "succeeded",
                                step_agent_diff: "diff --git a/app.rb b/app.rb\n+change\n", base_sha: "base-sha")
    workspace = instance_double(WorkflowWorkspace, setup: true, path: Pathname.new("/tmp/workspace"), base_ref: "origin/main")
    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:review_config).and_return(review_config)
    allow(ReviewEvidence::Capture).to receive(:call)
    allow(App::CoworkerReviewProjects).to receive(:call).and_return(
      App::CoworkerReviewProjects::Result.new(projects: [
        App::CoworkerReviewProjects::Project.new(
          id: "repo", label: "Repository", path: "", owner_config_path: ".syrus.yml",
          criteria: [ "Check rollout ownership" ]
        )
      ])
    )
  end

  it "hard-fails before invocation without a pinned reviewer" do
    review_step.update!(details: {})

    expect { handler.call }.to raise_error(ProviderRouting::Resolver::CoworkerReviewTargetRequired)
  end

  it "uses dedicated criteria, submission tool, and iteration artifact" do
    expect(handler).to receive(:run_agent) do |prompt:, required_mcp_tools:, **|
      expect(prompt).to include("accountable coworker", "Check rollout ownership")
      expect(required_mcp_tools).to eq(%w[submit_coworker_review])
      workflow.set_artifact!("coworker_review_iterations", [
        { "iteration" => 1, "critique" => "Operationally sound.", "verdict" => "approved" }
      ])
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

  it "requires reviewer memory persistence before succeeding" do
    reviewer = double("coworker reviewer")
    context = double("review context", persistence_state: "failed", persistence_error_details: { "message" => "push failed" })
    evidence = instance_double(ReviewEvidence, id: 42, state: "submitted", reviewer: reviewer)
    allow(run).to receive(:review_evidence).and_return(evidence)
    allow(run).to receive(:reload).and_return(run)
    allow(reviewer).to receive(:prepare_review_context!).and_return(context)
    allow(reviewer).to receive(:review_context_prompt).and_return("protected reviewer context")
    allow(reviewer).to receive(:finalize_review_memory!)
    allow(reviewer).to receive(:review_context_for).with(run).and_return(context)
    allow(ReviewEvidence::VerifySubmission).to receive(:call!).and_return(evidence)
    allow(handler).to receive(:run_agent) do
      workflow.set_artifact!("coworker_review_iterations", [
        { "iteration" => 1, "review_evidence_id" => 42, "critique" => "Needs repair.", "verdict" => "needs_work" }
      ])
    end

    expect { handler.call }.to raise_error(Steps::CoworkerReview::MemoryPersistenceFailed, /memory was not persisted/)
  end
end
