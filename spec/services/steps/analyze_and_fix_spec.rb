require "rails_helper"
require "tmpdir"

RSpec.describe Steps::AnalyzeAndFix do
  let(:user)       { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user) }
  let(:job)        { Factories.job(repository: repository, pr_number: 17, branch_name: "syrus/issue-42-1") }
  let(:workflow)   { Workflows::CiFailure.instantiate(job: job, artifacts: artifacts) }
  let(:step)       { workflow.steps.find_by(kind: "analyze_and_fix") }
  let(:run)        { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider) }
  let(:handler)    { described_class.new(run) }
  let(:artifacts) do
    {
      "head_sha" => "abc1234567890",
      "failed_checks" => [
        {
          "name" => "rspec",
          "conclusion" => "failure",
          "details_url" => "https://example.test/checks/1"
        }
      ]
    }
  end

  around do |ex|
    Dir.mktmpdir("syrus-analyze-and-fix") do |dir|
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
    allow(handler).to receive(:diff_against_default).and_return("diff --git a/spec/foo_spec.rb b/spec/foo_spec.rb\n+bar")
    allow(handler).to receive(:diff_against_sha).and_return("diff --git a/spec/foo_spec.rb b/spec/foo_spec.rb\n+bar")
    allow(handler).to receive(:head_sha).and_return("def456")

    issue = Struct.new(:title, :body).new("Add greeting helper", "We need a greeting helper.")
    allow_any_instance_of(GithubClient).to receive(:fetch_issue).and_return(issue)
  end

  it "builds and persists the CI failure prompt" do
    handler.call

    expect(run.reload.prompt).to include("CI is failing on PR")
    expect(run.prompt).to include("syrus/issue-42-1")
    expect(run.prompt).to include("abc1234")
    expect(run.prompt).to include("rspec")
  end

  it "includes Epic context in the CI repair prompt" do
    epic = Factories.epic(
      user: user,
      repository: repository,
      title: "Syrus CLI and test planning",
      description: "Keep repair work aligned with the current child Job."
    )
    job.update!(epic: epic)

    handler.call

    expect(run.reload.prompt).to include("#{epic.slug}: Syrus CLI and test planning")
    expect(run.prompt).to include("Do not implement the entire Epic")
  end

  it "skips prompt rebuild when run.prompt is already set" do
    run.update!(prompt: "pre-set prompt content")

    expect(Prompts::CiFailure).not_to receive(:new)
    handler.call

    expect(run.reload.prompt).to eq("pre-set prompt content")
  end

  it "uses the shared agentic change path to commit and capture the diff" do
    expect(handler).to receive(:commit_agent_changes)
      .with("Syrus analyze_and_fix step (will be rewritten by summarize_amend)")
    expect(handler).to receive(:assert_branch_history_intact!)

    handler.call

    expect(run.reload.agent_diff).to eq("diff --git a/spec/foo_spec.rb b/spec/foo_spec.rb\n+bar")
    expect(run.head_sha).to eq("def456")
  end
end
