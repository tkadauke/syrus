require "rails_helper"
require "ostruct"

RSpec.describe "Workflow merged PR guard" do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) do
    Factories.job(user: user, repository: repository, issue_number: 42,
                  pr_number: 7, branch_name: "syrus/issue-42-1")
  end

  it "succeeds a new workflow and closes the job when the PR already merged" do
    client = instance_double(GithubClient)
    allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
    expect(client).to receive(:pull_request)
      .with(repository.slug, 7, hash_including(bypass_cache: true))
      .and_return(OpenStruct.new(merged: true))

    workflow = job.workflows.last
    run = workflow.first_step.runs.first

    RunJob.perform_now(run.id)

    workflow.reload
    prepare, implement, summarize, pr_open = workflow.steps.order(:position)
    expect(workflow.state).to eq("succeeded")
    expect(prepare.state).to eq("succeeded")
    expect(implement.state).to eq("cancelled")
    expect(summarize.state).to eq("cancelled")
    expect(pr_open.state).to eq("cancelled")
    expect(run.reload.state).to eq("succeeded")
    expect(job.reload.state).to eq("closed")
    expect(job.closure_reason).to eq("pr_merged")
    expect(run.job_logs.pluck(:chunk).join("\n")).to include("pull request already merged")
  end

  it "succeeds the rebase workflow without rebasing when the PR already merged" do
    client = instance_double(GithubClient)
    allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
    expect(client).to receive(:pull_request)
      .with(repository.slug, 7, hash_including(bypass_cache: true))
      .and_return(OpenStruct.new(merged: true))
    expect(::AutoRebase).not_to receive(:new)

    workflow = Workflows::Rebase.instantiate(job: job)
    run = StepDispatcher.start_workflow(workflow)

    RunJob.perform_now(run.id)

    workflow.reload
    auto_rebase, agent_rebase, force_push = workflow.steps.order(:position)
    expect(workflow.state).to eq("succeeded")
    expect(auto_rebase.state).to eq("succeeded")
    expect(agent_rebase.state).to eq("cancelled")
    expect(force_push.state).to eq("cancelled")
    expect(run.reload.state).to eq("succeeded")
    expect(job.reload.state).to eq("closed")
    expect(job.closure_reason).to eq("pr_merged")
    expect(run.job_logs.pluck(:chunk).join("\n")).to include("pull request already merged")
  end
end
