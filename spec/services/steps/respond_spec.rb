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
    allow(handler).to receive(:diff_against_sha).and_return("diff --git a/foo.rb b/foo.rb\n+bar")
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

  it "builds chat feedback prompts from the chat_feedback markdown artifact" do
    chat_workflow = Workflows::ChatFeedback.instantiate(
      job: job,
      artifacts: { "chat_feedback" => "Please make the job timeline easier to scan.\n\n- Keep links visible." }
    )
    chat_step = chat_workflow.steps.find_by(kind: "respond")
    chat_run = chat_step.runs.create!(job: job, trigger_kind: chat_workflow.trigger_kind, agent_provider: chat_workflow.agent_provider)
    chat_handler = described_class.new(chat_run)
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(chat_handler).to receive(:workspace).and_return(fake_ws)
    allow(chat_handler).to receive(:run_agent)
    allow(chat_handler).to receive(:commit_agent_changes)
    allow(chat_handler).to receive(:assert_branch_history_intact!)
    allow(chat_handler).to receive(:diff_against_default).and_return("diff --git a/foo.rb b/foo.rb\n+bar")
    allow(chat_handler).to receive(:diff_against_sha).and_return("diff --git a/foo.rb b/foo.rb\n+bar")
    allow(chat_handler).to receive(:head_sha).and_return("abc789")

    chat_handler.call

    expect(chat_run.reload.prompt).to include("Please make the job timeline easier to scan.")
    expect(chat_run.prompt).to include("Keep links visible.")
    expect(chat_run.prompt).to include("Syrus Chat")
  end

  it "includes Epic context in the feedback prompt" do
    epic = Factories.epic(
      user: user,
      repository: repository,
      title: "Syrus CLI and test planning",
      description: "Keep feedback fixes aligned with the current child Job."
    )
    job.update!(epic: epic)

    handler.call

    expect(run.reload.prompt).to include("#{epic.slug}: Syrus CLI and test planning")
    expect(run.prompt).to include("Do not implement the entire Epic")
  end

  it "tags new comments with [NEW] when the artifact carries a feedback_cutoff" do
    cutoff = 1.minute.ago
    # one prior + one new
    workflow.update!(artifacts: workflow.artifacts.merge(
      "pr_comments" => [
        { "author" => "reviewer", "body" => "prior round comment", "created_at" => (cutoff - 1.hour).iso8601 },
        { "author" => "reviewer", "body" => "fresh round comment", "created_at" => (cutoff + 30.seconds).iso8601 }
      ],
      "feedback_cutoff" => cutoff.iso8601
    ))

    handler.call

    prompt = run.reload.prompt
    expect(prompt).to include("[NEW]")
    expect(prompt).to include("fresh round comment")
    expect(prompt).to include("prior round comment")
    # Prior comment is rendered but not tagged [NEW].
    new_position = prompt.index("[NEW]")
    prior_position = prompt.index("prior round comment")
    expect(prior_position).to be < new_position  # chronological order preserved
  end

  it "includes prior pr_comment workflow summaries when they exist" do
    # Build a prior succeeded pr_comment workflow with a summarize_amend
    # step whose Run carries an agent_summary.
    prior_wf = Workflows::PrFeedback.instantiate(job: job, artifacts: { "pr_comments" => [] })
    prior_wf.update!(state: "succeeded", started_at: 1.hour.ago, finished_at: 30.minutes.ago)
    summarize = prior_wf.steps.find_by(kind: "summarize_amend")
    Run.create!(job: job, step: summarize, trigger_kind: "pr_comment",
                state: "succeeded", agent_summary: "Tightened the greeting docstring per reviewer ask.")
    # Re-instantiate the current workflow so it's newer than the prior one
    new_wf = Workflows::PrFeedback.instantiate(job: job, artifacts: artifacts)
    new_step = new_wf.steps.find_by(kind: "respond")
    new_run = new_step.runs.create!(job: job, trigger_kind: new_wf.trigger_kind)
    new_handler = described_class.new(new_run)
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(new_handler).to receive(:workspace).and_return(fake_ws)
    allow(new_handler).to receive(:run_agent)
    allow(new_handler).to receive(:commit_agent_changes)
    allow(new_handler).to receive(:assert_branch_history_intact!)
    allow(new_handler).to receive(:diff_against_default).and_return("diff --git a/foo.rb b/foo.rb\n+bar")
    allow(new_handler).to receive(:diff_against_sha).and_return("diff --git a/foo.rb b/foo.rb\n+bar")
    allow(new_handler).to receive(:head_sha).and_return("abc456")

    new_handler.call

    expect(new_run.reload.prompt).to include("previous review rounds")
    expect(new_run.prompt).to include("Tightened the greeting docstring per reviewer ask.")
  end

  it "best-effort skips recent commits when git log fails" do
    # GitRunner will fail because the tmp workspace isn't a real repo.
    expect { handler.call }.not_to raise_error
    expect(run.reload.prompt).not_to include("Recent commits on the working branch")
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
          "output" => "review fix did not satisfy the grader"
        }
      ]
    ])
    run.update!(iteration: 2)

    handler.call

    expect(run.reload.prompt).to include("Add greeting helper")
    expect(run.prompt).to include("The previous iteration's quality graders flagged issues")
    expect(run.prompt).to include("Iteration 1")
    expect(run.prompt).to include("tests (exit 1)")
    expect(run.prompt).to include("review fix did not satisfy the grader")
  end

  it "skips prompt rebuild when run.prompt is already set" do
    run.update!(prompt: "pre-set prompt content")

    expect(Prompts::PrFeedback).not_to receive(:new)
    handler.call

    expect(run.reload.prompt).to eq("pre-set prompt content")
  end

  it "builds a chat feedback prompt from the workflow artifact" do
    chat_workflow = Workflows::ChatFeedback.instantiate(job: job, artifacts: { "chat_feedback" => "Please simplify the UI copy." })
    chat_step = chat_workflow.steps.find_by(kind: "respond")
    chat_run = chat_step.runs.create!(job: job, trigger_kind: chat_workflow.trigger_kind)
    chat_handler = described_class.new(chat_run)
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(chat_handler).to receive(:workspace).and_return(fake_ws)
    allow(chat_handler).to receive(:run_agent)
    allow(chat_handler).to receive(:commit_agent_changes)
    allow(chat_handler).to receive(:assert_branch_history_intact!)
    allow(chat_handler).to receive(:diff_against_default).and_return("diff --git a/foo.rb b/foo.rb\n+bar")
    allow(chat_handler).to receive(:diff_against_sha).and_return("diff --git a/foo.rb b/foo.rb\n+bar")
    allow(chat_handler).to receive(:head_sha).and_return("abc789")

    chat_handler.call

    expect(chat_run.reload.prompt).to include("Operator feedback from Syrus Chat")
    expect(chat_run.prompt).to include("Please simplify the UI copy.")
  end
end
