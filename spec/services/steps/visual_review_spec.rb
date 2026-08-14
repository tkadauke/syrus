require "rails_helper"

RSpec.describe Steps::VisualReview do
  let(:job) { Factories.job(issue_title: "Add a dashboard banner", issue_body: "Show a banner on the dashboard.") }
  let(:workflow) { job.workflows.last }
  let(:implement_step) { workflow.steps.find_by!(kind: "implement") }
  let(:implement_run) do
    Run.create!(job: job, step: implement_step, trigger_kind: "initial", state: "succeeded")
  end
  let(:loop_id) { "visual-review-loop-1" }
  let(:review_step) do
    Step.create!(
      workflow: workflow,
      kind: "visual_review",
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
    allow(SyrusYml).to receive(:load_repo).with(Pathname.new("/tmp/workspace")).and_raise(Errno::ENOENT)

    implement_step.update!(state: "succeeded")
    implement_run.update!(
      agent_diff: "diff --git a/app/views/dashboard/show.html.erb b/app/views/dashboard/show.html.erb\n+<div class=\"banner\">New</div>\n"
    )
  end

  describe "#parent_session_id" do
    before { handler.singleton_class.send(:public, :parent_session_id) }

    it "returns nil on iteration 1" do
      expect(handler.parent_session_id).to be_nil
    end

    it "returns the prior reviewer session on iteration 2 and never the implementer's session" do
      ProviderSession.create!(resumable: implement_run, session_id: "implementer-session", transcript_jsonl: "{}\n")

      prior_run = run
      prior_run.update!(state: "succeeded")
      review_step.update!(state: "succeeded")
      ProviderSession.create!(resumable: prior_run, session_id: "reviewer-session", transcript_jsonl: "{}\n")

      iteration_two_step = Step.create!(
        workflow: workflow,
        kind: "visual_review",
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
      expect(prompt).to include("submit_visual_review")
      expect(prompt).to include("diff --git a/app/views/dashboard/show.html.erb")
      expect(required_mcp_tools).to eq(%w[submit_visual_review])
      workflow.set_artifact!("visual_review_iterations", [
        { "iteration" => review_step.iteration, "critique" => "Looks correct.", "verdict" => "approved" }
      ])
    end

    handler.call

    expect(run.reload.prompt).to include("Show a banner on the dashboard.")
  end

  it "raises StepFailed when the reviewer does not submit findings" do
    allow(handler).to receive(:run_agent)

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /submit_visual_review/)
  end

  it "raises StepFailed when there is no succeeded implement diff" do
    implement_run.update!(agent_diff: nil)

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /no succeeded implement diff/)
  end

  context "in a standalone manual_visual_review workflow (no implement/respond step)" do
    let(:manual_job) { Factories.job_record(issue_title: "Add a dashboard banner", issue_body: "Show a banner on the dashboard.") }
    let(:manual_workflow) do
      Workflow.create!(job: manual_job, trigger_kind: "manual_visual_review", agent_provider: "claude", chain_template: [])
    end
    let(:manual_step) { Step.create!(workflow: manual_workflow, kind: "visual_review", position: 0, iteration: 1) }
    let(:manual_run) { Run.create!(job: manual_job, step: manual_step, trigger_kind: "manual_visual_review") }
    let(:manual_handler) { described_class.new(manual_run) }

    before do
      fake_ws = instance_double(WorkflowWorkspace, setup: true, path: Pathname.new("/tmp/workspace"), base_ref: "origin/main")
      allow(manual_handler).to receive(:workspace).and_return(fake_ws)
      allow(SyrusYml).to receive(:load_repo).with(Pathname.new("/tmp/workspace")).and_raise(Errno::ENOENT)
    end

    it "falls back to a fresh git diff against the default branch" do
      allow(manual_handler).to receive(:diff_against_default).and_return(
        "diff --git a/app/views/dashboard/show.html.erb b/app/views/dashboard/show.html.erb\n+<div class=\"banner\">New</div>\n"
      )

      expect(manual_handler).to receive(:run_agent) do |prompt: nil, **|
        expect(prompt).to include("diff --git a/app/views/dashboard/show.html.erb")
        manual_workflow.set_artifact!("visual_review_iterations", [
          { "iteration" => manual_step.iteration, "critique" => "Looks correct.", "verdict" => "approved" }
        ])
      end

      manual_handler.call
    end

    it "raises StepFailed when the branch has no changes to review" do
      allow(manual_handler).to receive(:diff_against_default).and_return("")

      expect { manual_handler.call }.to raise_error(Steps::Base::StepFailed, /no changes to review/)
    end
  end

  context "when the implementer's test plan recommends visual review" do
    before do
      workflow.set_artifact!("test_plan", {
        "steps" => [ "Open /dashboard" ],
        "notes" => nil,
        "visual_review_recommended" => true,
        "visual_review_reason" => "Added a new banner to the dashboard header."
      })
    end

    it "passes the recommendation into the prompt as a hint" do
      expect(handler).to receive(:run_agent) do |prompt: nil, **|
        expect(prompt).to include("recommended running visual review")
        expect(prompt).to include("Added a new banner to the dashboard header.")
        expect(prompt).to include("Treat this as a hint, not a directive")
        workflow.set_artifact!("visual_review_iterations", [
          { "iteration" => review_step.iteration, "critique" => "OK.", "verdict" => "approved" }
        ])
      end

      handler.call
    end
  end

  context "when workspace .syrus.yml has visual_review.seed_notes" do
    before do
      allow(SyrusYml).to receive(:load_repo).with(Pathname.new("/tmp/workspace")).and_return(
        SyrusYml::Config.new(
          prepare: nil, grade: nil, hooks: nil, adversarial_review: nil, agent_insight: nil,
          coverage: nil, formatters: [], generated: [], deployment_stages: [], preview: nil,
          visual_review: SyrusYml::VisualReviewConfig.new(
            enabled: true, rounds: 1, when_files_changed: nil,
            seed_notes: "Log in as demo@example.com / password."
          )
        )
      )
    end

    it "passes seed_notes into the prompt" do
      expect(handler).to receive(:run_agent) do |prompt: nil, **|
        expect(prompt).to include("Log in as demo@example.com / password.")
        workflow.set_artifact!("visual_review_iterations", [
          { "iteration" => review_step.iteration, "critique" => "OK.", "verdict" => "approved" }
        ])
      end

      handler.call
    end
  end

  context "when when_files_changed is configured and no changed file matches" do
    before do
      allow(handler.send(:workspace)).to receive(:base_ref).and_return("origin/main")
      allow(SyrusYml).to receive(:load_repo).with(Pathname.new("/tmp/workspace")).and_return(
        SyrusYml::Config.new(
          prepare: nil, grade: nil, hooks: nil, adversarial_review: nil, agent_insight: nil,
          coverage: nil, formatters: [], generated: [], deployment_stages: [], preview: nil,
          visual_review: SyrusYml::VisualReviewConfig.new(
            enabled: true, rounds: 1, when_files_changed: [ "app/frontend/**/*" ],
            seed_notes: nil
          )
        )
      )
      allow(GitRunner).to receive(:new).and_return(instance_double(GitRunner).tap do |git|
        allow(git).to receive(:run).with("diff", "--name-only", anything, chdir: "/tmp/workspace")
                                    .and_return("app/views/dashboard/show.html.erb\n")
      end)
    end

    it "skips the agent turn and records a skipped verdict" do
      expect(handler).not_to receive(:run_agent)

      handler.call

      expect(workflow.reload.artifact("visual_review_iterations")).to eq([
        {
          "iteration" => review_step.iteration,
          "critique" => "No changed files matched the configured visual_review.when_files_changed patterns.",
          "verdict" => "skipped"
        }
      ])
    end
  end

  context "when when_files_changed is configured and a changed file matches" do
    before do
      allow(handler.send(:workspace)).to receive(:base_ref).and_return("origin/main")
      allow(SyrusYml).to receive(:load_repo).with(Pathname.new("/tmp/workspace")).and_return(
        SyrusYml::Config.new(
          prepare: nil, grade: nil, hooks: nil, adversarial_review: nil, agent_insight: nil,
          coverage: nil, formatters: [], generated: [], deployment_stages: [], preview: nil,
          visual_review: SyrusYml::VisualReviewConfig.new(
            enabled: true, rounds: 1, when_files_changed: [ "app/views/**/*" ],
            seed_notes: nil
          )
        )
      )
      allow(GitRunner).to receive(:new).and_return(instance_double(GitRunner).tap do |git|
        allow(git).to receive(:run).with("diff", "--name-only", anything, chdir: "/tmp/workspace")
                                    .and_return("app/views/dashboard/show.html.erb\n")
      end)
    end

    it "invokes the agent as normal" do
      expect(handler).to receive(:run_agent) do |prompt: nil, **|
        workflow.set_artifact!("visual_review_iterations", [
          { "iteration" => review_step.iteration, "critique" => "OK.", "verdict" => "approved" }
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
      Step.create!(workflow: feedback_workflow, kind: "visual_review", position: 2, iteration: 1,
                   loop_id: "fb-loop-1")
    end
    let(:fb_run) { Run.create!(job: feedback_job, step: fb_review_step, trigger_kind: "pr_comment") }
    let(:fb_handler) { described_class.new(fb_run) }

    before do
      fake_ws = instance_double(WorkflowWorkspace, setup: true, path: Pathname.new("/tmp/workspace"))
      allow(fb_handler).to receive(:workspace).and_return(fake_ws)
      allow(SyrusYml).to receive(:load_repo).with(Pathname.new("/tmp/workspace")).and_raise(Errno::ENOENT)
      respond_run
      feedback_workflow.set_artifact!("pr_comments", [
        { "author" => "alice", "body" => "The banner looks broken on mobile.", "path" => nil, "line" => nil }
      ])
    end

    it "reads the respond step diff, not an implement diff" do
      expect(fb_handler).to receive(:run_agent) do |prompt: nil, **|
        expect(prompt).to include("addressed feedback")
        expect(prompt).to include("respond step")
        feedback_workflow.set_artifact!("visual_review_iterations", [
          { "iteration" => 1, "critique" => "Fine.", "verdict" => "approved" }
        ])
      end

      fb_handler.call
    end

    it "includes the PR feedback context and workflow kind in the prompt" do
      expect(fb_handler).to receive(:run_agent) do |prompt: nil, **|
        expect(prompt).to include("PR comment feedback workflow")
        expect(prompt).to include("alice")
        expect(prompt).to include("The banner looks broken on mobile.")
        feedback_workflow.set_artifact!("visual_review_iterations", [
          { "iteration" => 1, "critique" => "Fine.", "verdict" => "approved" }
        ])
      end

      fb_handler.call
    end
  end
end
