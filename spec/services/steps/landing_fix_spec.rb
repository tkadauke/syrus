require "rails_helper"
require "tmpdir"

RSpec.describe Steps::LandingFix do
  let(:user)       { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job)        { Factories.job(repository: repository, issue_number: 42, pr_number: 17, branch_name: "syrus/issue-42-1") }
  let(:workflow)   { Workflows::AutoMerge.instantiate(job: job) }
  let(:step)       { landing_fix_step }
  let(:run)        { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider, iteration: step.iteration) }
  let(:handler)    { described_class.new(run) }

  around do |ex|
    Dir.mktmpdir("syrus-landing-fix") do |dir|
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
    allow(handler).to receive(:diff_against_default).and_return("diff --git a/app.rb b/app.rb\n+ok")
    allow(handler).to receive(:diff_against_sha).and_return("diff --git a/app.rb b/app.rb\n+ok")
    allow(handler).to receive(:head_sha).and_return("def456")
    allow(handler).to receive(:recent_branch_commits).and_return([
      { sha: "abcdef123456", subject: "Fix dashboard state" }
    ])

    issue = Struct.new(:title, :body).new("Keep dashboard honest", "Run final checks after rebasing.")
    allow_any_instance_of(GithubClient).to receive(:fetch_issue).and_return(issue)
  end

  it "builds and persists the landing fix prompt" do
    handler.call

    expect(run.reload.prompt).to include("final merge-readiness pass")
    expect(run.prompt).to include("acme/widgets#17")
    expect(run.prompt).to include("Keep dashboard honest")
    expect(run.prompt).to include("abcdef1 Fix dashboard state")
  end

  it "includes Epic context in the landing fix prompt" do
    epic = Factories.epic(
      user: user,
      repository: repository,
      title: "Syrus CLI and test planning",
      description: "Keep landing repairs scoped to the current child Job."
    )
    job.update!(epic: epic)

    handler.call

    expect(run.reload.prompt).to include("#{epic.slug}: Syrus CLI and test planning")
    expect(run.prompt).to include("Do not implement the entire Epic")
  end

  it "uses external PR metadata in the prompt when repairing a same-repository external PR" do
    external_job = Job.create!(
      user: user,
      owner_user: user,
      repository: repository,
      kind: "external_pr",
      issue_number: nil,
      external_pr_number: 99,
      state: "implemented"
    )
    external_workflow = Workflow.create!(
      job: external_job,
      trigger_kind: "external_pr_merge",
      agent_provider: external_job.agent_provider,
      chain_template: []
    )
    external_workflow.set_artifact!("external_pr_head_ref", "contributor-branch")
    external_step = Step.create!(
      workflow: external_workflow,
      kind: "landing_fix",
      position: 3,
      iteration: 2,
      loop_id: SecureRandom.uuid
    )
    external_run = external_step.runs.create!(
      job: external_job,
      trigger_kind: external_workflow.trigger_kind,
      agent_provider: external_workflow.agent_provider,
      iteration: external_step.iteration
    )
    external_handler = described_class.new(external_run)
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(external_handler).to receive(:workspace).and_return(fake_ws)
    allow(external_handler).to receive(:run_agent)
    allow(external_handler).to receive(:commit_agent_changes)
    allow(external_handler).to receive(:assert_branch_history_intact!)
    allow(external_handler).to receive(:diff_against_default).and_return("diff --git a/app.rb b/app.rb\n+ok")
    allow(external_handler).to receive(:diff_against_sha).and_return("diff --git a/app.rb b/app.rb\n+ok")
    allow(external_handler).to receive(:head_sha).and_return("def456")
    allow(external_handler).to receive(:recent_branch_commits).and_return([])

    external_handler.call

    expect(external_run.reload.prompt).to include("acme/widgets#99")
    expect(external_run.prompt).to include("contributor-branch")
  end


  it "appends recorded grade failure feedback to the prompt" do
    workflow.set_artifact!("iterations", [
      [
        {
          "name" => "rspec",
          "required" => true,
          "status" => "failed",
          "exit_code" => 1,
          "output" => "expected green but got red"
        }
      ]
    ])

    handler.call

    expect(run.reload.prompt).to include("The previous iteration's quality graders flagged issues")
    expect(run.prompt).to include("rspec")
    expect(run.prompt).to include("expected green but got red")
  end

  it "commits through the shared agentic change path and captures the diff" do
    expect(handler).to receive(:commit_agent_changes).with("Syrus pre-merge fix")
    expect(handler).to receive(:assert_branch_history_intact!)

    handler.call

    expect(run.reload.agent_diff).to eq("diff --git a/app.rb b/app.rb\n+ok")
    expect(run.head_sha).to eq("def456")
  end

  def landing_fix_step
    workflow.steps.find_by(kind: "landing_fix") || begin
      grader_collect = workflow.steps.find_by!(kind: "grader_collect")
      Step.create!(
        workflow: workflow,
        kind: "landing_fix",
        position: grader_collect.position + 1,
        iteration: 2,
        loop_id: grader_collect.loop_id
      )
    end
  end
end
