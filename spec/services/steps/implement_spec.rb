require "rails_helper"
require "tmpdir"

RSpec.describe Steps::Implement do
  let(:job)      { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:step)     { workflow.steps.find_by(kind: "implement") }
  let(:run)      do
    step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind)
  end
  let(:handler)  { described_class.new(run) }

  around do |ex|
    Dir.mktmpdir("syrus-implement") do |dir|
      @ws_path = Pathname.new(dir)
      ex.run
    end
  end

  before do
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(handler).to receive(:workspace).and_return(fake_ws)
    allow(handler).to receive(:run_agent)
    allow(handler).to receive(:commit_agent_changes)
    allow(handler).to receive(:assert_branch_history_intact!)
    allow(handler).to receive(:diff_against_default).and_return("diff --git a/foo.rb b/foo.rb\n+bar")
    allow(handler).to receive(:head_sha).and_return("abc123")

    issue = Struct.new(:title, :body).new("Add greeting helper", "We need a greeting helper.")
    allow(handler).to receive(:fetch_issue).and_return(issue)
  end

  describe "prompt building" do
    it "builds and persists the prompt from Prompts::Implement" do
      handler.call
      expect(run.reload.prompt).to include("Add greeting helper")
      expect(run.reload.prompt).to include("Phased execution note: you're running the **implement** step")
      expect(run.reload.prompt).not_to include("quality graders flagged issues")
    end

    it "appends grade failure feedback on later loop iterations" do
      workflow.set_artifact!("iterations", [
        [
          {
            "name" => "tests",
            "status" => "failed",
            "required" => true,
            "exit_code" => 1,
            "log_path" => ".syrus/grade-output/iteration-1/tests.log"
          }
        ]
      ])
      run.update!(iteration: 2)

      handler.call

      expect(run.reload.prompt).to include("Add greeting helper")
      expect(run.reload.prompt).to include("The previous iteration's quality graders flagged issues")
      expect(run.reload.prompt).to include("Iteration 1")
      expect(run.reload.prompt).to include("tests (exit 1)")
    end

    it "skips prompt rebuild when run.prompt is already set" do
      run.update!(prompt: "pre-set prompt content")
      expect(Prompts::Implement).not_to receive(:new)
      handler.call
      expect(run.reload.prompt).to eq("pre-set prompt content")
    end

    context "when workflow has replay_context in artifacts" do
      before { workflow.update!(artifacts: { "replay_context" => "Please fix the failing tests." }) }

      it "includes the operator context in the prompt" do
        handler.call
        expect(run.reload.prompt).to include("Please fix the failing tests.")
        expect(run.reload.prompt).to include("Additional context from the operator")
      end

      it "positions the context between the issue content and the git safety block" do
        handler.call
        prompt = run.reload.prompt
        issue_pos   = prompt.index("Add greeting helper")
        context_pos = prompt.index("Additional context from the operator")
        safety_pos  = prompt.index(Prompts::GitSafety::TEXT)
        expect(context_pos).to be > issue_pos
        expect(safety_pos).to be > context_pos
      end
    end

    context "when workflow has no replay_context" do
      it "does not inject an operator context section" do
        handler.call
        expect(run.reload.prompt).not_to include("Additional context from the operator")
      end
    end
  end
end
