require "rails_helper"

RSpec.describe PollExternalPrJob do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  # An open Job whose issue was preempted: external_pr_number set, no Syrus PR.
  let(:job) do
    j = Factories.job(repository: repository, issue_number: 42)
    # Stub the auto-created initial Run so the Job stays open without a real run.
    j.initial_run.tap { |r| r.start!; r.succeed!; r.save! }
    j.update!(external_pr_number: 9)
    j
  end

  let(:slug) { "acme/widgets" }
  let(:external_pr_url) { "https://api.github.com/repos/acme/widgets/pulls/9" }

  def stub_external_pr(state: "open", merged: false, merge_commit_sha: nil)
    body = { number: 9, state: state, merged: merged }
    body[:merge_commit_sha] = merge_commit_sha if merge_commit_sha
    stub_request(:get, external_pr_url).with(query: hash_including({})).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: body.to_json
    )
  end

  describe "close conditions" do
    it "closes the Job with external_pr_merged when the external PR is merged" do
      stub_external_pr(state: "closed", merged: true)
      expect { described_class.perform_now(job.id) }.to change { job.reload.state }.to("closed")
      expect(job.closure_reason).to eq("external_pr_merged")
    end

    it "stores merge_commit_sha as landed_sha when the external PR is merged" do
      stub_external_pr(state: "closed", merged: true, merge_commit_sha: "deadbeef1234")
      described_class.perform_now(job.id)
      expect(job.reload.landed_sha).to eq("deadbeef1234")
    end

    it "leaves landed_sha nil when merge_commit_sha is absent" do
      stub_external_pr(state: "closed", merged: true)
      described_class.perform_now(job.id)
      expect(job.reload.landed_sha).to be_nil
    end

    it "does not set landed_sha when the PR is only closed (not merged)" do
      stub_external_pr(state: "closed", merged: false)
      described_class.perform_now(job.id)
      expect(job.reload.landed_sha).to be_nil
    end

    it "closes the Job with external_pr_closed when the external PR is closed without merging" do
      stub_external_pr(state: "closed", merged: false)
      described_class.perform_now(job.id)
      expect(job.reload.closure_reason).to eq("external_pr_closed")
    end

    it "leaves the Job open when the external PR is still open" do
      stub_external_pr(state: "open", merged: false)
      expect { described_class.perform_now(job.id) }.not_to change { job.reload.state }
    end
  end

  describe "guards" do
    it "no-ops when the Job is already closed" do
      job.close_with_reason!("preempted")
      described_class.perform_now(job.id)
      # No GitHub call should be made
      expect(WebMock).not_to have_requested(:get, external_pr_url)
    end

    it "no-ops when the Job has no external_pr_number" do
      job.update!(external_pr_number: nil)
      described_class.perform_now(job.id)
      expect(WebMock).not_to have_requested(:get, external_pr_url)
    end

    it "no-ops when the Job also has a Syrus pr_number (handled by PollPullRequestJob)" do
      job.update!(pr_number: 7)
      described_class.perform_now(job.id)
      expect(WebMock).not_to have_requested(:get, external_pr_url)
    end

    it "no-ops for an archived repository" do
      repository.update!(archived_at: Time.current)
      described_class.perform_now(job.id)
      expect(WebMock).not_to have_requested(:get, external_pr_url)
    end
  end

  describe "external_pr kind Jobs" do
    let(:external_pr_job) do
      Job.create!(
        user: user,
        repository: repository,
        kind: "external_pr",
        external_pr_number: 9,
        state: "implemented"
      )
    end

    it "closes the external_pr Job with external_pr_merged when the PR is merged" do
      stub_external_pr(state: "closed", merged: true)
      expect { described_class.perform_now(external_pr_job.id) }
        .to change { external_pr_job.reload.state }.to("closed")
      expect(external_pr_job.closure_reason).to eq("external_pr_merged")
    end

    it "closes the external_pr Job with external_pr_closed when the PR closes without merging" do
      stub_external_pr(state: "closed", merged: false)
      described_class.perform_now(external_pr_job.id)
      expect(external_pr_job.reload.closure_reason).to eq("external_pr_closed")
    end

    it "leaves the external_pr Job open when the PR is still open" do
      stub_external_pr(state: "open", merged: false)
      stub_request(:get, "https://api.github.com/repos/acme/widgets/pulls/9/reviews")
        .with(query: hash_including({})).to_return(
          status: 200, headers: { "Content-Type" => "application/json" }, body: "[]"
        )
      expect { described_class.perform_now(external_pr_job.id) }
        .not_to change { external_pr_job.reload.state }
    end

    it "polls even when pr_number is also set on an external_pr kind Job" do
      external_pr_job.update_columns(pr_number: 55)
      stub_external_pr(state: "closed", merged: true)
      expect { described_class.perform_now(external_pr_job.id) }
        .to change { external_pr_job.reload.state }.to("closed")
    end
  end

  describe "review reactions for external_pr Jobs" do
    let(:external_pr_job) do
      Job.create!(
        user: user,
        repository: repository,
        kind: "external_pr",
        external_pr_number: 9,
        state: "implemented"
      )
    end

    let(:reviews_url) { "https://api.github.com/repos/acme/widgets/pulls/9/reviews" }

    def stub_reviews(reviews = [])
      stub_request(:get, reviews_url).with(query: hash_including({})).to_return(
        status: 200, headers: { "Content-Type" => "application/json" },
        body: reviews.to_json
      )
    end

    it "flips an implemented external_pr Job to approved on an APPROVED review" do
      stub_external_pr(state: "open", merged: false)
      stub_reviews([
        { id: 1, state: "APPROVED", submitted_at: Time.current.iso8601,
          html_url: "https://github.com/acme/widgets/pull/9#pullrequestreview-1", user: { login: "reviewer" } }
      ])

      expect { described_class.perform_now(external_pr_job.id) }
        .to change { external_pr_job.reload.state }.from("implemented").to("approved")

      external_pr_job.reload
      expect(external_pr_job.approved_via).to eq("github_review")
      expect(external_pr_job.approval_evidence).to eq(
        "github_review_url" => "https://github.com/acme/widgets/pull/9#pullrequestreview-1"
      )
    end

    it "sets needs_attention_reason on a CHANGES_REQUESTED review" do
      stub_external_pr(state: "open", merged: false)
      stub_reviews([
        { id: 1, state: "CHANGES_REQUESTED", submitted_at: Time.current.iso8601,
          html_url: nil, user: { login: "reviewer" } }
      ])

      described_class.perform_now(external_pr_job.id)

      expect(external_pr_job.reload.needs_attention_reason).to eq("upstream_pr_changes_requested")
    end

    it "clears needs_attention_reason once CHANGES_REQUESTED is resolved by APPROVED" do
      external_pr_job.update!(needs_attention: true, needs_attention_reason: "upstream_pr_changes_requested")
      stub_external_pr(state: "open", merged: false)
      stub_reviews([
        { id: 1, state: "APPROVED", submitted_at: Time.current.iso8601,
          html_url: "https://github.com/acme/widgets/pull/9#pullrequestreview-1", user: { login: "reviewer" } }
      ])

      described_class.perform_now(external_pr_job.id)

      expect(external_pr_job.reload.needs_attention_reason).to be_nil
    end

    it "does not react to reviews when the PR is merged" do
      stub_external_pr(state: "closed", merged: true)

      described_class.perform_now(external_pr_job.id)

      expect(WebMock).not_to have_requested(:get, reviews_url)
    end

    it "does not react to reviews when the PR is closed without merging" do
      stub_external_pr(state: "closed", merged: false)

      described_class.perform_now(external_pr_job.id)

      expect(WebMock).not_to have_requested(:get, reviews_url)
    end

    it "does not react to reviews for non-external_pr Jobs polled via the preempted-issue path" do
      stub_external_pr(state: "open", merged: false)

      described_class.perform_now(job.id)

      expect(WebMock).not_to have_requested(:get, "https://api.github.com/repos/acme/widgets/pulls/9/reviews")
    end
  end
end
