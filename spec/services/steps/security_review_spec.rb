require "rails_helper"

RSpec.describe Steps::SecurityReview do
  let(:job) { Factories.job(issue_title: "Secure change", issue_body: "Add a protected endpoint.") }
  let(:workflow) { job.latest_workflow }
  let(:implement_step) { workflow.steps.find_by!(kind: "implement") }
  let(:review_step) { Step.create!(workflow: workflow, kind: "security_review", position: 100, iteration: 1, loop_id: "security-loop") }
  let(:run) { Run.create!(job: job, step: review_step, trigger_kind: "initial") }
  let(:handler) { described_class.new(run) }

  before do
    implement_step.update!(state: "succeeded")
    implement_step.runs.create!(job: job, trigger_kind: "initial", state: "succeeded",
      step_agent_diff: "diff --git a/app.rb b/app.rb\n+protected endpoint\n", base_sha: "base-sha")
    workspace = instance_double(WorkflowWorkspace, setup: true, path: Pathname.new("/tmp/security-workspace"), base_ref: "origin/main")
    allow(handler).to receive(:workspace).and_return(workspace)
    allow(App::SecurityReviewProjects).to receive(:call).and_return(
      App::AdversarialReviewProjects::Result.new(projects: [])
    )
  end

  it "runs a read-only security reviewer and requires its dedicated MCP submission" do
    expect(handler).to receive(:run_agent) do |prompt:, required_mcp_tools:, disallowed_tools:, **|
      expect(prompt).to include("security_review", "authentication and authorization", "submit_security_review")
      expect(required_mcp_tools).to eq(%w[submit_security_review])
      expect(disallowed_tools).to eq(%w[ReportFindings])
      workflow.set_artifact!("security_review_iterations", [ { "verdict" => "approved" } ])
    end

    handler.call
  end

  it "resumes only a prior security reviewer in the same loop" do
    review_step.update!(state: "succeeded")
    run.update!(state: "succeeded")
    ProviderSession.create!(resumable: run, session_id: "security-session", transcript_jsonl: "{}\n")
    next_step = Step.create!(workflow: workflow, kind: "security_review", position: 101, iteration: 2, loop_id: "security-loop")
    next_run = next_step.runs.create!(job: job, trigger_kind: "initial")
    next_handler = described_class.new(next_run)
    next_handler.singleton_class.send(:public, :parent_session_id)

    expect(next_handler.parent_session_id).to eq("security-session")
  end
end
