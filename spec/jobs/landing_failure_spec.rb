require "rails_helper"
require "ostruct"

RSpec.describe "landing failure handling" do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", auto_merge_enabled: true) }
  let(:job) do
    Factories.job_record(
      user: user,
      repository: repository,
      issue_number: 42,
      pr_number: 7,
      branch_name: "syrus/issue-42-1",
      state: "implemented"
    )
  end

  def pr
    OpenStruct.new(
      merged: false,
      state: "open",
      mergeable_state: "blocked",
      labels: [],
      head: OpenStruct.new(sha: "abc")
    )
  end

  before do
    allow(AppSetting).to receive(:runs_paused?).and_return(false)
    allow(RunHostAdmission).to receive(:call) do |run:, **|
      RunHostAdmission::Decision.new(
        action: "admit",
        reason: "landing_failure_spec",
        delay: nil,
        details: { "run_id" => run.id }
      )
    end
    allow(WorkerCapabilities).to receive(:current).and_return(
      { capabilities: { "os" => [ "linux" ] } }
    )
  end

  it "returns a failed landing Job to implemented with a reason" do
    job.approve!(via: "github_review")
    job.start_landing!
    job.save!
    workflow = Workflow.create!(job: job, trigger_kind: "auto_merge")
    step = Step.create!(workflow: workflow, kind: "auto_merge", position: 0)
    run = step.runs.create!(job: job, trigger_kind: "auto_merge", agent_provider: workflow.agent_provider)

    allow_any_instance_of(GithubClient).to receive(:pull_request).and_return(pr)
    allow_any_instance_of(GithubClient).to receive(:pr_reviews).and_return([ OpenStruct.new(state: "APPROVED") ])
    allow_any_instance_of(GithubClient).to receive(:pr_issue_comments).and_return([])
    allow_any_instance_of(GithubClient).to receive(:pr_commits).and_return([])

    expect {
      RunJob.perform_now(run.id)
    }.to raise_error(Steps::Base::StepFailed, /auto_merge/)

    expect(job.reload).to be_implemented
    expect(job.landing_failure_reason).to include("auto_merge")
    expect(job.approved_at).to be_nil
  end
end
