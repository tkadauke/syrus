require "rails_helper"

RSpec.describe Steps::AdversarialReview do
  let(:job) { Factories.job(issue_title: "Add review loop", issue_body: "Review the implementation independently.") }
  let(:workflow) { job.workflows.last }
  let(:implement_step) { workflow.steps.find_by!(kind: "implement") }
  let(:implement_run) do
    Run.create!(job: job, step: implement_step, trigger_kind: "initial", state: "succeeded")
  end
  let(:loop_id) { "review-loop-1" }
  let(:review_step) do
    Step.create!(
      workflow: workflow,
      kind: "adversarial_review",
      position: 100,
      iteration: 1,
      loop_id: loop_id
    )
  end
  let(:run) { Run.create!(job: job, step: review_step, trigger_kind: "initial") }
  let(:handler) { described_class.new(run) }

  before do
    fake_ws = instance_double(WorkflowWorkspace, setup: true, path: Pathname.new("/tmp/workspace"))
    allow(handler).to receive(:workspace).and_return(fake_ws)

    implement_step.update!(state: "succeeded")
    implement_run.update!(
      agent_diff: "diff --git a/app.rb b/app.rb\n+puts 'review me'\n"
    )
  end

  describe "#parent_session_id" do
    before { handler.singleton_class.send(:public, :parent_session_id) }

    it "returns nil on iteration 1" do
      expect(handler.parent_session_id).to be_nil
    end

    it "returns the prior reviewer session on iteration 2 and never the implementer's session" do
      ClaudeSession.create!(resumable: implement_run, session_id: "implementer-session", transcript_jsonl: "{}\n")

      prior_step = review_step
      prior_step.update!(state: "succeeded")
      prior_run = run
      prior_run.update!(state: "succeeded")
      ClaudeSession.create!(resumable: prior_run, session_id: "reviewer-session", transcript_jsonl: "{}\n")

      iteration_two_step = Step.create!(
        workflow: workflow,
        kind: "adversarial_review",
        position: 101,
        iteration: 2,
        loop_id: loop_id
      )
      iteration_two_run = Run.create!(job: job, step: iteration_two_step, trigger_kind: "initial")
      iteration_two_handler = described_class.new(iteration_two_run)
      iteration_two_handler.singleton_class.send(:public, :parent_session_id)

      expect(iteration_two_handler.parent_session_id).to eq("reviewer-session")
      expect(iteration_two_handler.parent_session_id).not_to eq("implementer-session")
    end
  end

  it "calls run_agent without using the change-step commit path" do
    expect(handler).not_to receive(:perform_agentic_change_step)
    expect(handler).to receive(:run_agent) do |prompt: nil, **|
      expect(prompt).to include("submit_adversarial_review")
      expect(prompt).to include("diff --git a/app.rb b/app.rb")
      workflow.set_artifact!("adversarial_review_iterations", [
        { "iteration" => review_step.iteration, "critique" => "Looks sound.", "verdict" => "approved" }
      ])
    end

    handler.call

    expect(run.reload.prompt).to include("Review the implementation independently.")
  end

  it "raises StepFailed when the reviewer does not submit findings" do
    allow(handler).to receive(:run_agent)

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /submit_adversarial_review/)
  end
end
