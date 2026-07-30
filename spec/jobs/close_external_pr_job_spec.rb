require "rails_helper"

RSpec.describe CloseExternalPrJob do
  let(:user)       { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  let(:job) do
    Job.create!(
      user: user,
      repository: repository,
      kind: "external_pr",
      external_pr_number: 9,
      state: "implemented"
    )
  end

  let(:slug)           { "acme/widgets" }
  let(:pr_url)         { "https://api.github.com/repos/acme/widgets/pulls/9" }
  let(:comment_url)    { "https://api.github.com/repos/acme/widgets/issues/9/comments" }
  let(:close_pr_url)   { "https://api.github.com/repos/acme/widgets/pulls/9" }

  def stub_pr(state: "open", merged: false)
    stub_request(:get, pr_url).with(query: hash_including({})).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { number: 9, state: state, merged: merged }.to_json
    )
  end

  def stub_close_pr
    stub_request(:patch, close_pr_url).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { number: 9, state: "closed", merged: false }.to_json
    )
  end

  def stub_comment
    stub_request(:post, comment_url).to_return(
      status: 201, headers: { "Content-Type" => "application/json" },
      body: { id: 1, body: "ok" }.to_json
    )
  end

  before do
    # Close the job so it's in the right state for the background job.
    job.close_with_reason!("cancelled")
  end

  it "closes the GitHub PR and posts a comment when the PR is still open" do
    stub_pr
    stub_close_pr
    stub_comment

    described_class.perform_now(job.id)

    expect(WebMock).to have_requested(:patch, close_pr_url)
      .with(body: hash_including("state" => "closed"))
    expect(WebMock).to have_requested(:post, comment_url)
      .with(body: hash_including("body" => include("Syrus Job was closed")))
  end

  it "skips closing when the GitHub PR is already merged" do
    stub_pr(state: "closed", merged: true)

    described_class.perform_now(job.id)

    expect(WebMock).not_to have_requested(:patch, close_pr_url)
    expect(WebMock).not_to have_requested(:post, comment_url)
  end

  it "skips closing when the GitHub PR is already closed" do
    stub_pr(state: "closed", merged: false)

    described_class.perform_now(job.id)

    expect(WebMock).not_to have_requested(:patch, close_pr_url)
    expect(WebMock).not_to have_requested(:post, comment_url)
  end

  it "no-ops when the Job is not found" do
    described_class.perform_now(-1)

    expect(WebMock).not_to have_requested(:get, pr_url)
  end

  it "no-ops when the Job is not closed" do
    open_job = Job.create!(
      user: user,
      repository: repository,
      kind: "external_pr",
      external_pr_number: 10,
      state: "implemented"
    )

    described_class.perform_now(open_job.id)

    expect(WebMock).not_to have_requested(:get, "https://api.github.com/repos/acme/widgets/pulls/10")
  end

  it "no-ops when the Job has no external_pr_number" do
    job2 = Job.create!(
      user: user,
      repository: repository,
      kind: "external_pr",
      external_pr_number: 11,
      state: "implemented"
    )
    job2.close_with_reason!("cancelled")
    job2.update_columns(external_pr_number: nil)

    described_class.perform_now(job2.id)

    expect(WebMock).not_to have_requested(:get, "https://api.github.com/repos/acme/widgets/pulls/11")
  end

  it "rescues GitHub errors and logs a warning instead of raising" do
    stub_pr
    stub_request(:patch, close_pr_url).to_return(status: 422, body: "Unprocessable Entity")

    expect(Rails.logger).to receive(:warn).with(include("CloseExternalPrJob"))

    expect { described_class.perform_now(job.id) }.not_to raise_error
  end

  describe "Job model callback" do
    let(:client) { instance_double(GithubClient) }

    before do
      allow(GithubClient).to receive(:for).and_return(client)
    end

    it "enqueues CloseExternalPrJob when an external_pr Job is closed with a non-GitHub reason" do
      pending_job = Job.create!(
        user: user,
        repository: repository,
        kind: "external_pr",
        external_pr_number: 20,
        state: "implemented"
      )

      expect { pending_job.close_with_reason!("cancelled") }
        .to have_enqueued_job(CloseExternalPrJob).with(pending_job.id)
    end

    it "does not enqueue CloseExternalPrJob when closure reason is external_pr_merged" do
      pending_job = Job.create!(
        user: user,
        repository: repository,
        kind: "external_pr",
        external_pr_number: 21,
        state: "implemented"
      )

      expect { pending_job.close_with_reason!("external_pr_merged") }
        .not_to have_enqueued_job(CloseExternalPrJob)
    end

    it "does not enqueue CloseExternalPrJob when closure reason is external_pr_closed" do
      pending_job = Job.create!(
        user: user,
        repository: repository,
        kind: "external_pr",
        external_pr_number: 22,
        state: "implemented"
      )

      expect { pending_job.close_with_reason!("external_pr_closed") }
        .not_to have_enqueued_job(CloseExternalPrJob)
    end

    it "does not enqueue CloseExternalPrJob for non-external_pr kinds" do
      issue_job = Factories.job(repository: repository, issue_number: 42)
      issue_job.initial_run.tap { |r| r.start!; r.succeed!; r.save! }

      expect { issue_job.cancel_active_runs_and_close!("cancelled") }
        .not_to have_enqueued_job(CloseExternalPrJob)
    end
  end
end
