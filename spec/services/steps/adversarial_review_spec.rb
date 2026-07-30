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
    expect(handler).to receive(:run_agent) do |prompt: nil, required_mcp_tools: nil, **|
      expect(prompt).to include("submit_adversarial_review")
      expect(prompt).to include("diff --git a/app.rb b/app.rb")
      expect(required_mcp_tools).to eq(%w[submit_adversarial_review])
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

  context "when workspace .syrus.yml has criteria" do
    before do
      syrus_yml_path = Pathname.new("/tmp/workspace/.syrus.yml")
      allow(syrus_yml_path).to receive(:exist?).and_return(true)
      allow(File).to receive(:read).with(syrus_yml_path.to_s).and_return(<<~YAML)
        adversarial_review:
          rounds: 1
          criteria:
            - Verify endpoints enforce authentication
            - No internal state in errors
      YAML
      allow(SyrusYml).to receive(:load_repo).with(Pathname.new("/tmp/workspace")).and_return(
        SyrusYml::Config.new(
          prepare: nil,
          grade: nil,
          hooks: nil,
          adversarial_review: SyrusYml::AdversarialReviewConfig.new(
            rounds: 1,
            criteria: [ "Verify endpoints enforce authentication", "No internal state in errors" ]
          ),
          coverage: nil,
          formatters: [],
          generated: [],
          reconciliation_mode: nil,
          deployment_stages: []
        )
      )
    end

    it "passes criteria to the prompt" do
      expect(handler).to receive(:run_agent) do |prompt: nil, **|
        expect(prompt).to include("pay particular attention")
        expect(prompt).to include("Verify endpoints enforce authentication")
        expect(prompt).to include("No internal state in errors")
        workflow.set_artifact!("adversarial_review_iterations", [
          { "iteration" => review_step.iteration, "critique" => "OK.", "verdict" => "approved" }
        ])
      end

      handler.call
    end
  end

  context "when workspace .syrus.yml is missing" do
    before do
      allow(SyrusYml).to receive(:load_repo).with(Pathname.new("/tmp/workspace")).and_raise(Errno::ENOENT)
    end

    it "defaults criteria to [] without raising" do
      expect(handler).to receive(:run_agent) do |prompt: nil, **|
        expect(prompt).not_to include("pay particular attention")
        workflow.set_artifact!("adversarial_review_iterations", [
          { "iteration" => review_step.iteration, "critique" => "Fine.", "verdict" => "approved" }
        ])
      end

      handler.call
    end
  end

  context "when workspace .syrus.yml has a parse error" do
    before do
      allow(SyrusYml).to receive(:load_repo).with(Pathname.new("/tmp/workspace")).and_raise(SyrusYml::ParseError, "bad yaml")
    end

    it "defaults criteria to [] without raising" do
      expect(handler).to receive(:run_agent) do |prompt: nil, **|
        expect(prompt).not_to include("pay particular attention")
        workflow.set_artifact!("adversarial_review_iterations", [
          { "iteration" => review_step.iteration, "critique" => "Fine.", "verdict" => "approved" }
        ])
      end

      handler.call
    end
  end

  context "in a pr_comment feedback workflow" do
    let(:user) { Factories.user(github_token: "ghp_test") }
    let(:repository) { Factories.repository(user: user) }
    let(:feedback_job) do
      Factories.job_record(
        user: user,
        repository: repository,
        state: "open",
        issue_title: "Feedback job",
        issue_body: "Original task body."
      )
    end
    let(:feedback_workflow) do
      Workflow.create!(
        job: feedback_job,
        trigger_kind: "pr_comment",
        agent_provider: "claude",
        chain_template: []
      )
    end
    let(:respond_step) do
      Step.create!(workflow: feedback_workflow, kind: "respond", position: 1, iteration: 1,
                   state: "succeeded", loop_id: "fb-loop-1")
    end
    let(:respond_run) do
      Run.create!(job: feedback_job, step: respond_step, trigger_kind: "pr_comment", state: "succeeded",
                  agent_diff: "diff --git a/foo.rb b/foo.rb\n+# addressed feedback\n")
    end
    let(:fb_review_step) do
      Step.create!(workflow: feedback_workflow, kind: "adversarial_review", position: 2, iteration: 1,
                   loop_id: "fb-loop-1")
    end
    let(:fb_run) { Run.create!(job: feedback_job, step: fb_review_step, trigger_kind: "pr_comment") }
    let(:fb_handler) { described_class.new(fb_run) }

    before do
      fake_ws = instance_double(WorkflowWorkspace, setup: true, path: Pathname.new("/tmp/workspace"))
      allow(fb_handler).to receive(:workspace).and_return(fake_ws)
      respond_run # ensure persisted
      feedback_workflow.set_artifact!("pr_comments", [
        { "author" => "alice", "body" => "Please add error handling.", "path" => nil, "line" => nil }
      ])
    end

    it "reads the respond step diff, not an implement diff" do
      expect(fb_handler).to receive(:run_agent) do |prompt: nil, **|
        expect(prompt).to include("addressed feedback")
        expect(prompt).to include("respond step")
        feedback_workflow.set_artifact!("adversarial_review_iterations", [
          { "iteration" => 1, "critique" => "Fine.", "verdict" => "approved" }
        ])
      end

      fb_handler.call
    end

    it "includes the PR feedback context and workflow kind in the prompt" do
      expect(fb_handler).to receive(:run_agent) do |prompt: nil, **|
        expect(prompt).to include("PR comment feedback workflow")
        expect(prompt).to include("alice")
        expect(prompt).to include("Please add error handling.")
        feedback_workflow.set_artifact!("adversarial_review_iterations", [
          { "iteration" => 1, "critique" => "Fine.", "verdict" => "approved" }
        ])
      end

      fb_handler.call
    end

    it "raises StepFailed when no respond diff exists" do
      respond_run.update!(agent_diff: nil)

      expect { fb_handler.call }.to raise_error(Steps::Base::StepFailed, /respond diff/)
    end
  end

  context "in a chat_feedback workflow" do
    let(:user) { Factories.user(github_token: "ghp_test") }
    let(:repository) { Factories.repository(user: user) }
    let(:chat_job) do
      Factories.job_record(user: user, repository: repository, state: "open",
                           issue_title: "Chat job", issue_body: "Original task.")
    end
    let(:chat_workflow) do
      Workflow.create!(
        job: chat_job,
        trigger_kind: "chat_feedback",
        agent_provider: "claude",
        chain_template: []
      )
    end
    let(:chat_respond_step) do
      Step.create!(workflow: chat_workflow, kind: "respond", position: 1, iteration: 1,
                   state: "succeeded", loop_id: "chat-loop-1")
    end
    let(:chat_respond_run) do
      Run.create!(job: chat_job, step: chat_respond_step, trigger_kind: "chat_feedback", state: "succeeded",
                  agent_diff: "diff --git a/bar.rb b/bar.rb\n+# chat addressed\n")
    end
    let(:chat_review_step) do
      Step.create!(workflow: chat_workflow, kind: "adversarial_review", position: 2, iteration: 1,
                   loop_id: "chat-loop-1")
    end
    let(:chat_run) { Run.create!(job: chat_job, step: chat_review_step, trigger_kind: "chat_feedback") }
    let(:chat_handler) { described_class.new(chat_run) }

    before do
      fake_ws = instance_double(WorkflowWorkspace, setup: true, path: Pathname.new("/tmp/workspace"))
      allow(chat_handler).to receive(:workspace).and_return(fake_ws)
      chat_respond_run # ensure persisted
      chat_workflow.set_artifact!("chat_feedback", "Please refactor the helper method.")
    end

    it "includes chat feedback context and workflow kind in the prompt" do
      expect(chat_handler).to receive(:run_agent) do |prompt: nil, **|
        expect(prompt).to include("chat feedback workflow")
        expect(prompt).to include("Please refactor the helper method.")
        chat_workflow.set_artifact!("adversarial_review_iterations", [
          { "iteration" => 1, "critique" => "Looks good.", "verdict" => "approved" }
        ])
      end

      chat_handler.call
    end
  end
end
