require "rails_helper"
require "ostruct"

RSpec.describe Workflows::ExternalPrMerge do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", auto_merge_enabled: true) }
  # external_pr Jobs must be created in :implemented state (validated on create).
  # Factories.job_record always overrides state to "closed" then update_columns,
  # so we use Job.create! directly for external_pr kind.
  let(:job) do
    Job.create!(
      user: user,
      owner_user: user,
      repository: repository,
      kind: "external_pr",
      issue_number: nil,
      external_pr_number: 99,
      state: "implemented"
    )
  end
  let(:client) { instance_double(GithubClient) }

  def pr(is_fork: false)
    head_repo = is_fork ? "contributor/widgets" : "acme/widgets"
    OpenStruct.new(
      head: OpenStruct.new(repo: OpenStruct.new(full_name: head_repo), ref: "feature", sha: "abc123")
    )
  end

  before do
    allow(GithubClient).to receive(:for).and_return(client)
    allow(client).to receive(:pull_request).and_return(pr(is_fork: true))
    allow(client).to receive(:create_pr_review)
  end

  it "materializes the step chain with prepare but without push" do
    workflow = described_class.instantiate(job: job)

    expect(workflow.steps.order(:position).pluck(:kind)).to eq(
      %w[mergeability_preflight prepare grader_fanout grader_collect external_pr_merge]
    )
  end

  it "materializes a landing_fix retry loop for same-repository external PRs" do
    allow(client).to receive(:pull_request).and_return(pr(is_fork: false))

    workflow = described_class.instantiate(job: job)

    expect(workflow.steps.order(:position).pluck(:kind)).to eq(
      %w[mergeability_preflight prepare grader_fanout grader_collect external_pr_merge]
    )
    expect(workflow.steps.where.not(loop_id: nil).pluck(:kind)).to eq(%w[grader_fanout grader_collect])
    expect(workflow.chain_template).to include(
      hash_including(
        "type" => "retry_until",
        "repair" => %w[landing_fix],
        "check" => %w[grader_fanout grader_collect]
      )
    )
  end

  it "uses a check-only chain for fork external PRs" do
    allow(client).to receive(:pull_request).and_return(pr(is_fork: true))

    workflow = described_class.instantiate(job: job)

    expect(workflow.steps.where.not(loop_id: nil)).to be_empty
    expect(workflow.chain_template).to eq([
      { "type" => "step", "kind" => "mergeability_preflight" },
      { "type" => "step", "kind" => "prepare" },
      { "type" => "step", "kind" => "grader_fanout" },
      { "type" => "step", "kind" => "grader_collect" },
      { "type" => "step", "kind" => "external_pr_merge" }
    ])
  end

  it "uses the external_pr_merge trigger kind" do
    workflow = described_class.instantiate(job: job)

    expect(workflow.trigger_kind).to eq("external_pr_merge")
  end

  it "enqueues on the merges queue" do
    expect(described_class.queue_name).to eq(:merges)
  end

  describe "after_fail" do
    let(:workflow) do
      job.approve!(via: "operator")
      job.start_landing!
      job.save!
      described_class.instantiate(job: job).tap { |w| w.update!(state: "failed") }
    end

    it "calls LandingFailureHandler to revert the job to :implemented" do
      expect(LandingFailureHandler).to receive(:call).with(
        job: job, reason: anything, run: nil
      )

      described_class.after_fail(workflow)
    end

    it "is a no-op when the job is not landing" do
      job.update_columns(state: "approved")
      non_landing_workflow = described_class.instantiate(job: job)
      non_landing_workflow.update!(state: "failed")

      expect(LandingFailureHandler).not_to receive(:call)

      described_class.after_fail(non_landing_workflow)
    end

    context "when graders failed" do
      before do
        grader_step = workflow.steps.create!(
          kind: "grader",
          state: "failed",
          position: 99,
          details: { "name" => "rspec", "required" => true }
        )
        workflow.steps.create!(
          kind: "grader_collect",
          state: "failed",
          position: 100
        )
        allow(LandingFailureHandler).to receive(:call)
      end

      it "posts a REQUEST_CHANGES review on a fork PR" do
        allow(client).to receive(:pull_request).and_return(pr(is_fork: true))

        described_class.after_fail(workflow)

        expect(client).to have_received(:create_pr_review)
          .with("acme/widgets", 99, hash_including(event: "REQUEST_CHANGES"))
      end

      it "posts a REQUEST_CHANGES review on a same-repo PR" do
        allow(client).to receive(:pull_request).and_return(pr(is_fork: false))

        described_class.after_fail(workflow)

        expect(client).to have_received(:create_pr_review)
          .with("acme/widgets", 99, hash_including(event: "REQUEST_CHANGES"))
      end

      it "includes failed grader names in the review body" do
        allow(client).to receive(:pull_request).and_return(pr)

        described_class.after_fail(workflow)

        expect(client).to have_received(:create_pr_review)
          .with(anything, anything, hash_including(body: include("rspec")))
      end

      it "still calls LandingFailureHandler even when review posting fails" do
        allow(client).to receive(:pull_request).and_raise(StandardError, "network error")

        expect(LandingFailureHandler).to receive(:call)

        described_class.after_fail(workflow)
      end
    end

    context "when graders did not fail (e.g. ExternalPrMerge step failed)" do
      before { allow(LandingFailureHandler).to receive(:call) }

      it "does not post a review" do
        described_class.after_fail(workflow)

        expect(client).not_to have_received(:create_pr_review)
      end
    end
  end

  describe "after_success" do
    it "triggers the landing queue to process the next job" do
      workflow = described_class.instantiate(job: job)
      workflow.update!(state: "succeeded")

      expect(LandingQueueProcessor).to receive(:try_land!).with(no_args)

      described_class.after_success(workflow)
    end
  end
end
