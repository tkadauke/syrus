require "rails_helper"

RSpec.describe CiRepair::ManualRerun do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) do
    Factories.job_record(
      user: user,
      repository: repository,
      state: "implemented",
      branch_name: "syrus/direct-2265",
      pr_number: 2265,
      last_ci_handled_sha: sha
    )
  end
  let(:sha) { "2265abcdef000000000000000000000000000000" }
  let(:client) { instance_double(GithubClient) }
  let(:pr) { double("PullRequest", head: double("Head", sha: sha)) }
  let(:detail) do
    {
      pending?: false,
      any_failed?: true,
      all_passed?: false,
      failed_checks: [
        { name: "rspec", conclusion: "failure", summary: "1 failure", html_url: "https://github.com/acme/widgets/runs/1" }
      ]
    }
  end

  before do
    allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
    allow(client).to receive(:pull_request).with("acme/widgets", 2265, bypass_cache: true).and_return(pr)
    allow(client).to receive(:check_runs_detail_for).with("acme/widgets", sha).and_return(detail)
  end

  it "reruns CI repair for JOB-2265 even when the handled SHA already matches" do
    result = described_class.call(
      job: job,
      reason: "JOB-2265 CI repair left the head unchanged.",
      instructions: "Inspect why the prior repair produced no diff."
    )

    expect(result.workflow).to have_attributes(job: job, trigger_kind: "ci_failure")
    expect(result.run).to be_present
    expect(job.reload.last_ci_handled_sha).to eq(sha)
    expect(result.cleared_handled_sha).to be true
    expect(result.workflow.artifact("head_sha")).to eq(sha)
    expect(result.workflow.artifact("failed_checks").first).to include("error_context")
    expect(result.workflow.artifact("manual_ci_repair")).to include(
      "reason" => "JOB-2265 CI repair left the head unchanged.",
      "instructions" => "Inspect why the prior repair produced no diff.",
      "clear_handled_sha" => true
    )
  end

  it "limits repeated repairs on the same SHA unless explicitly overridden" do
    2.times do
      Workflows::CiFailure.instantiate(job: job, artifacts: { "head_sha" => sha, "failed_checks" => [] })
        .update_columns(state: "succeeded")
    end

    expect {
      described_class.call(job: job, reason: "Try again.")
    }.to raise_error(ArgumentError, /already has 2 CI repair workflows/)

    expect {
      described_class.call(job: job, reason: "Operator inspected the loop.", override_repeated_sha: true)
    }.to change { job.workflows.where(trigger_kind: "ci_failure").count }.by(1)
  end

  it "refuses to enqueue when checks no longer fail" do
    allow(client).to receive(:check_runs_detail_for).with("acme/widgets", sha).and_return(
      { pending?: false, any_failed?: false, all_passed?: true, failed_checks: [] }
    )

    expect {
      described_class.call(job: job, reason: "Try again.")
    }.to raise_error(ArgumentError, /Current PR checks are passing/)
  end
end
