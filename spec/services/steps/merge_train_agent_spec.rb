require "rails_helper"
require "tmpdir"

RSpec.describe Steps::MergeTrainAgent, :ci_only do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) do
    Factories.job_record(
      user: user,
      repository: repository,
      issue_number: 1,
      pr_number: 501,
      branch_name: "syrus/issue-1",
      state: "landing"
    )
  end
  let(:train) do
    MergeTrain.create!(
      repository: repository,
      priority: job.priority,
      base_branch: "main",
      integration_branch: "syrus/job-bundle-agent",
      integration_sha: "integration_sha"
    )
  end
  let(:workflow) do
    Workflow.create!(
      job: job,
      trigger_kind: "merge_train",
      agent_provider: job.agent_provider,
      chain_template: [],
      artifacts: { "merge_train_id" => train.id }
    )
  end
  let(:step) { Step.create!(workflow: workflow, kind: "merge_train_agent", position: 1) }
  let(:run) { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider) }
  let(:handler) { described_class.new(run) }

  around do |example|
    Dir.mktmpdir("syrus-merge-train-agent") do |dir|
      @ws_path = Pathname.new(dir)
      example.run
    end
  end

  before do
    MergeTrainMember.create!(merge_train: train, job: job, position: 0)
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(handler).to receive(:workspace).and_return(fake_ws)
    allow(handler).to receive(:head_sha).and_return("base_sha")
    allow(handler).to receive(:assert_branch_history_intact!)
    allow(handler).to receive(:diff_against_sha).and_return("")

    git = instance_double(GitRunner)
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(git).to receive(:run).with("checkout", "-B", train.integration_branch, train.integration_sha, chdir: @ws_path.to_s)
    allow(git).to receive(:run).with("status", "--porcelain", chdir: @ws_path.to_s)
      .and_return("")
    allow(git).to receive(:run).with("add", "-A", chdir: @ws_path.to_s)
    allow(git).to receive(:run).with("reset", "--", ".syrus/merge_train_agent.json", chdir: @ws_path.to_s)
    allow(git).to receive(:run).with("diff", "--cached", "--name-only", chdir: @ws_path.to_s).and_return("")
  end

  it "records a durable withdrawal action before failing the old train" do
    allow(handler).to receive(:run_agent) do
      @ws_path.join(".syrus").mkpath
      @ws_path.join(".syrus/merge_train_agent.json").write(
        JSON.dump("action" => "withdraw", "job_slug" => job.slug, "evidence" => "only this member owns the failing test")
      )
    end

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /withdrew #{job.slug}/)

    expect(workflow.reload.artifact(Steps::MergeTrainAgent::WITHDRAWN_JOB_ID_ARTIFACT)).to eq(job.id)
    expect(workflow.artifact(Steps::MergeTrainAgent::ARTIFACT_KEY)).to include(
      "result" => "withdrawn",
      "job_id" => job.id,
      "job_slug" => job.slug,
      "evidence" => "only this member owns the failing test"
    )
  end
end
