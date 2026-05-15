require "rails_helper"
require "tmpdir"

RSpec.describe Steps::Respond do
  let(:user)     { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user) }
  let(:job)      { Factories.job(repository: repository) }
  let(:workflow) { Workflows::PrFeedback.instantiate(job: job, artifacts: artifacts) }
  let(:step)     { workflow.steps.find_by(kind: "respond") }
  let(:run)      { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider) }
  let(:handler)  { described_class.new(run) }
  let(:artifacts) do
    {
      "pr_comments" => [
        {
          "author" => "reviewer",
          "body" => "Please tighten the docstring.",
          "created_at" => Time.current.iso8601
        }
      ]
    }
  end

  around do |ex|
    Dir.mktmpdir("syrus-respond") do |dir|
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
    allow_any_instance_of(GithubClient).to receive(:fetch_issue).and_return(issue)
  end

  it "uses the shared agentic change path to commit and capture the diff" do
    expect(handler).to receive(:commit_agent_changes)
      .with("Syrus respond step (will be rewritten by summarize_amend)")
    expect(handler).to receive(:assert_branch_history_intact!)

    handler.call

    expect(run.reload.agent_diff).to eq("diff --git a/foo.rb b/foo.rb\n+bar")
    expect(run.head_sha).to eq("abc123")
  end

  it "builds and persists the prompt from Prompts::PrFeedback" do
    handler.call

    expect(run.reload.prompt).to include("Add greeting helper")
    expect(run.prompt).to include("Please tighten the docstring.")
    expect(run.prompt).not_to include("quality graders flagged issues")
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
    expect(run.prompt).to include("The previous iteration's quality graders flagged issues")
    expect(run.prompt).to include("Iteration 1")
    expect(run.prompt).to include("tests (exit 1)")
  end

  it "skips prompt rebuild when run.prompt is already set" do
    run.update!(prompt: "pre-set prompt content")

    expect(Prompts::PrFeedback).not_to receive(:new)
    handler.call

    expect(run.reload.prompt).to eq("pre-set prompt content")
  end
end
