require "rails_helper"
require "tmpdir"

RSpec.describe Steps::LocalModeHandoffFix do
  let(:user)       { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job)        { Factories.job(repository: repository, branch_name: "syrus/local-mode-99") }
  let(:workflow)   { Workflows::LocalModeHandoff.instantiate(job: job) }
  let(:step)       { local_mode_handoff_fix_step }
  let(:run) do
    step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider,
      iteration: step.iteration
    )
  end
  let(:handler)    { described_class.new(run) }

  around do |ex|
    Dir.mktmpdir("syrus-local-mode-handoff-fix") do |dir|
      @ws_path = Pathname.new(dir)
      ex.run
    end
  end

  before do
    fake_ws = instance_double(
      WorkflowWorkspace,
      setup: nil,
      path: @ws_path,
      branch_name: "syrus/local-mode-99"
    )
    allow(handler).to receive(:workspace).and_return(fake_ws)
    allow(handler).to receive(:run_agent)
    allow(handler).to receive(:commit_agent_changes)
    allow(handler).to receive(:assert_branch_history_intact!)
    allow(handler).to receive(:diff_against_default).and_return("diff --git a/app/models/job.rb b/app/models/job.rb\n+ok")
    allow(handler).to receive(:diff_against_sha).and_return("diff --git a/app/models/job.rb b/app/models/job.rb\n+ok")
    allow(handler).to receive(:head_sha).and_return("fed789")
    allow(handler).to receive(:recent_branch_commits).and_return([
      { sha: "abcdef123456", subject: "Implement from local mode" }
    ])

    issue = Struct.new(:title, :body).new("Repair handoff", "Keep the local handoff behavior.")
    allow_any_instance_of(GithubClient).to receive(:fetch_issue).and_return(issue)
  end

  it "builds and persists the local mode handoff repair prompt with grader feedback" do
    workflow.set_artifact!("iterations", [
      [
        {
          "name" => "rspec",
          "required" => true,
          "status" => "failed",
          "exit_code" => 1,
          "output" => "expected local mode repair to pass"
        }
      ]
    ])

    handler.call

    expect(run.reload.prompt).to include("Local Mode handoff repair")
    expect(run.prompt).to include("acme/widgets")
    expect(run.prompt).to include("syrus/local-mode-99")
    expect(run.prompt).to include("rspec")
    expect(run.prompt).to include("expected local mode repair to pass")
  end

  it "commits through the shared agentic change path and captures the diff" do
    expect(handler).to receive(:commit_agent_changes).with("Syrus local mode handoff grader fix")
    expect(handler).to receive(:assert_branch_history_intact!)

    handler.call

    expect(run.reload.agent_diff).to eq("diff --git a/app/models/job.rb b/app/models/job.rb\n+ok")
    expect(run.head_sha).to eq("fed789")
  end

  def local_mode_handoff_fix_step
    workflow.steps.find_by(kind: "local_mode_handoff_fix") || begin
      grader_collect = workflow.steps.find_by!(kind: "grader_collect")
      Step.create!(
        workflow: workflow,
        kind: "local_mode_handoff_fix",
        position: grader_collect.position + 1,
        iteration: 2,
        loop_id: grader_collect.loop_id
      )
    end
  end
end
