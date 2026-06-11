require "rails_helper"

RSpec.describe Steps::TestPlan do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job(repository: repository) }
  let(:workflow) { Workflows::Initial.instantiate(job: job) }
  let(:implement_step) { workflow.steps.find_by!(kind: "implement") }
  let(:test_plan_step) { workflow.steps.find_by!(kind: "test_plan") }
  let(:run) do
    Run.create!(job: job, step: test_plan_step, trigger_kind: "initial").tap { |r| r.start!; r.save! }
  end
  let(:handler) { described_class.new(run) }

  before do
    fake_ws = instance_double(WorkflowWorkspace, setup: true, path: Pathname.new("/tmp/workspace"))
    allow(handler).to receive(:workspace).and_return(fake_ws)
  end

  it "sets the test-plan prompt, invokes the agent with a short turn budget, and verifies the artifact" do
    expect(handler).to receive(:run_agent) do |prompt:, max_turns:|
      expect(prompt).to include("submit_test_plan")
      expect(max_turns).to eq(described_class::TEST_PLAN_TURN_BUDGET)
      workflow.set_artifact!("test_plan", { steps: [ "Run bin/rspec" ], notes: nil })
    end

    handler.call

    expect(run.reload.prompt).to include("submit_test_plan")
  end

  it "raises StepFailed when the agent does not call submit_test_plan" do
    allow(handler).to receive(:run_agent)

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /didn't call submit_test_plan/)
  end

  it "resumes from the succeeded implement session" do
    implement_step.update!(state: "succeeded")
    implement_run = Run.create!(job: job, step: implement_step, trigger_kind: "initial", state: "succeeded")
    ClaudeSession.create!(resumable: implement_run, session_id: "implement-thread", transcript_jsonl: "{}\n")

    handler.singleton_class.send(:public, :parent_session_id)

    expect(handler.parent_session_id).to eq("implement-thread")
  end
end
