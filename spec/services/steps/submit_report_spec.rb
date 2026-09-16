require "rails_helper"

RSpec.describe Steps::SubmitReport do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) do
    Job.create!(
      user: user,
      repository: repository,
      kind: "direct",
      issue_number: nil,
      issue_title: "Investigation: what's slow?",
      issue_body: "Investigate: why does /dashboard feel slow?",
      investigation: true
    )
  end
  let(:workflow) { Workflows::Investigation.instantiate(job: job) }
  let(:investigate_step) { workflow.steps.find_by!(kind: "investigate") }
  let!(:investigate_run) do
    Run.create!(job: job, step: investigate_step, trigger_kind: "investigation", state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)
  end
  let(:submit_report_step) { workflow.steps.find_by!(kind: "submit_report") }
  let(:run) do
    Run.create!(job: job, step: submit_report_step, trigger_kind: "investigation").tap { |r| r.start!; r.save! }
  end
  let(:handler) { described_class.new(run) }

  before do
    fake_ws = instance_double(WorkflowWorkspace, setup: true, path: Pathname.new("/tmp/workspace"))
    allow(handler).to receive(:workspace).and_return(fake_ws)
  end

  it "skips the agent call when the investigation report is already submitted" do
    workflow.set_artifact!("investigation_report", { title: "Findings", narrative: "It's slow because...", findings: [] })

    expect(handler).not_to receive(:run_agent)
    handler.call
  end

  it "raises before invoking the agent when there is no completed investigate run" do
    investigate_run.destroy!

    expect(handler).not_to receive(:run_agent)
    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /no completed investigate run/)
  end

  it "sets the submit-report prompt, invokes the agent with a short turn budget, and verifies the artifact" do
    expect(handler).to receive(:run_agent) do |prompt:, max_turns:, required_mcp_tools:|
      expect(prompt).to include("submit_report")
      expect(max_turns).to eq(described_class::SUBMIT_REPORT_TURN_BUDGET)
      expect(required_mcp_tools).to eq(%w[submit_report])
      workflow.set_artifact!("investigation_report", { title: "Findings", narrative: "It's slow because...", findings: [] })
    end

    handler.call

    expect(run.reload.prompt).to include("submit_report")
  end

  it "raises StepFailed when the agent does not call submit_report" do
    allow(handler).to receive(:run_agent)

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /didn't call submit_report/)
  end

  it "resumes from the investigate step's session" do
    ProviderSession.create!(resumable: investigate_run, session_id: "sess-123", transcript_jsonl: "x")

    expect(handler.send(:parent_session_id)).to eq("sess-123")
  end
end
