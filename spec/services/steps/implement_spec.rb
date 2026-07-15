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
    allow(handler).to receive(:diff_against_sha).and_return("diff --git a/foo.rb b/foo.rb\n+bar")
    allow(handler).to receive(:head_sha).and_return("abc123")

    issue = Struct.new(:title, :body).new("Add greeting helper", "We need a greeting helper.")
    allow(handler).to receive(:fetch_issue).and_return(issue)
    allow(handler).to receive(:fetch_initial_issue_comments).and_return([])
  end

  describe "prompt building" do
    it "uses the shared agentic change path to commit and capture the diff" do
      expect(handler).to receive(:commit_agent_changes)
        .with("Syrus implement step (will be rewritten by summarize)")
      expect(handler).to receive(:assert_branch_history_intact!)

      handler.call

      expect(run.reload.agent_diff).to eq("diff --git a/foo.rb b/foo.rb\n+bar")
      expect(run.head_sha).to eq("abc123")
    end

    it "builds and persists the prompt from Prompts::Implement" do
      handler.call
      expect(run.reload.prompt).to include("Add greeting helper")
      expect(run.reload.prompt).to include("Original issue body")
      expect(run.reload.prompt).to include("Phased execution note: you're running the **implement** step")
      expect(run.reload.prompt).not_to include("quality graders flagged issues")
    end

    it "records an empty initial issue comment artifact when the issue has no comments" do
      handler.call

      expect(workflow.reload.artifact("initial_issue_comments")).to eq([])
      expect(run.reload.prompt).not_to include("Subsequent issue comments")
    end

    it "includes Epic context without expanding the current Job scope" do
      epic = Factories.epic(
        user: job.user,
        repository: job.repository,
        title: "Syrus CLI and test planning",
        description: "Track one builds the Rails planning step. Track two builds the Go CLI."
      )
      job.update!(epic: epic)

      handler.call

      prompt = run.reload.prompt
      expect(prompt).to include("#{epic.slug}: Syrus CLI and test planning")
      expect(prompt).to include("Track one builds the Rails planning step")
      expect(prompt).to include("Do not implement the entire Epic")
      expect(prompt).to include("Implement only the Job described above")
    end

    it "records initial issue comments and includes them in the implement prompt" do
      comments = [
        { "author" => "octavia", "body" => "The original scope is too broad; only update the API.", "created_at" => "2026-05-01T10:00:00Z" },
        { "author" => "lucius", "body" => "Also keep the existing endpoint name.", "created_at" => "2026-05-01T11:00:00Z" }
      ]
      allow(handler).to receive(:fetch_initial_issue_comments).and_return(comments)

      handler.call

      expect(workflow.reload.artifact("initial_issue_comments")).to eq(comments)
      prompt = run.reload.prompt
      expect(prompt).to include("Subsequent issue comments")
      expect(prompt.index("The original scope is too broad")).to be < prompt.index("Also keep the existing endpoint name")
    end

    it "fetches issue comments chronologically and filters Syrus-authored bot noise" do
      AppSetting.current.update!(github_app_slug: "tkadauke-syrus")
      user_struct = Struct.new(:login)
      comment_struct = Struct.new(:user, :body, :created_at)
      earlier = Time.zone.parse("2026-05-01T10:00:00Z")
      later = Time.zone.parse("2026-05-01T11:00:00Z")
      client = instance_double(GithubClient)
      allow(client).to receive(:issue_comments).with(job.repository.slug, job.issue_number).and_return([
        comment_struct.new(user_struct.new("tkadauke-syrus[bot]"), "Syrus internal bookkeeping", later),
        comment_struct.new(user_struct.new("octavia"), "First clarification", earlier),
        comment_struct.new(user_struct.new("tkadauke-syrus[bot]"), "Syrus on behalf of @lucius\n\nSecond clarification", later)
      ])
      allow(GithubClient).to receive(:for).and_return(client)
      allow(handler).to receive(:fetch_initial_issue_comments).and_call_original

      handler.call

      comments = workflow.reload.artifact("initial_issue_comments")
      expect(comments.map { |comment| comment["body"] }).to eq([
        "First clarification",
        "Syrus on behalf of @lucius\n\nSecond clarification"
      ])
      expect(run.reload.prompt).not_to include("Syrus internal bookkeeping")
    end

    it "appends grade failure feedback on later loop iterations" do
      workflow.set_artifact!("iterations", [
        [
          {
            "name" => "tests",
            "status" => "failed",
            "required" => true,
            "exit_code" => 1,
            "log_path" => ".syrus/grade-output/iteration-1/tests.log",
            "output" => "expected greeting helper to exist"
          }
        ]
      ])
      run.update!(iteration: 2)

      handler.call

      expect(run.reload.prompt).to include("Add greeting helper")
      expect(run.reload.prompt).to include("The previous iteration's quality graders flagged issues")
      expect(run.reload.prompt).to include("Iteration 1")
      expect(run.reload.prompt).to include("tests (exit 1)")
      expect(run.reload.prompt).to include("expected greeting helper to exist")
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
