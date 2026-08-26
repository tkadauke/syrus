require "rails_helper"

RSpec.describe DeliveryStatus do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def policy_double(promotion: false, hotfix_sync: false, upstream_export: false, track: "default")
    instance_double(
      DeliveryPolicy,
      promotion_enabled?: promotion,
      hotfix_sync_enabled?: hotfix_sync,
      upstream_export_enabled?: upstream_export,
      job_delivery_track: track
    )
  end

  def status_for(job, **policy_opts)
    described_class.for(job: job, policy: policy_double(**policy_opts))
  end

  it "resolves to waiting_for_local_approval before local approval, matching today's behavior with no delivery config" do
    job = Factories.job_record(repository: repository, state: "implemented")

    expect(status_for(job)).to eq(:waiting_for_local_approval)
  end

  it "resolves to approved_for_local_landing once the job is approved" do
    job = Factories.job_record(repository: repository, state: "approved")

    expect(status_for(job)).to eq(:approved_for_local_landing)
  end

  it "resolves to approved_for_local_landing once the local PR has landed, with no promotion configured" do
    job = Factories.job_record(repository: repository, state: "closed", closure_reason: "pr_merged")

    expect(status_for(job)).to eq(:approved_for_local_landing)
  end

  it "resolves to waiting_for_promotion once local landing succeeds and promotion is configured but no promotion PR link exists yet" do
    job = Factories.job_record(repository: repository, state: "closed", closure_reason: "pr_merged")

    expect(status_for(job, promotion: true)).to eq(:waiting_for_promotion)
  end

  it "resolves to waiting_for_upstream_approval once a promotion PR link is open" do
    job = Factories.job_record(repository: repository, state: "closed", closure_reason: "pr_merged")
    JobPrLink.create!(job: job, role: JobPrLink::ROLE_PROMOTION, pr_number: 7, metadata: { "pr_state" => "open" })

    expect(status_for(job, promotion: true)).to eq(:waiting_for_upstream_approval)
  end

  it "resolves to upstream_merged once the promotion PR link records a merge" do
    job = Factories.job_record(repository: repository, state: "closed", closure_reason: "pr_merged")
    JobPrLink.create!(job: job, role: JobPrLink::ROLE_PROMOTION, pr_number: 7, metadata: { "pr_state" => "merged" })

    expect(status_for(job, promotion: true)).to eq(:upstream_merged)
  end

  it "resolves to upstream_closed_without_merge once the promotion PR link closes without merging" do
    job = Factories.job_record(repository: repository, state: "closed", closure_reason: "pr_merged")
    JobPrLink.create!(job: job, role: JobPrLink::ROLE_PROMOTION, pr_number: 7, metadata: { "pr_state" => "closed" })

    expect(status_for(job, promotion: true)).to eq(:upstream_closed_without_merge)
  end

  it "resolves to syncing_hotfix once a non-default-track landing succeeds and hotfix-sync is configured" do
    job = Factories.job_record(repository: repository, state: "closed", closure_reason: "pr_merged", delivery_track: "hotfix")

    expect(status_for(job, hotfix_sync: true, track: "hotfix")).to eq(:syncing_hotfix)
  end

  it "resolves to delivery_needs_attention when the job itself has failed" do
    job = Factories.job_record(repository: repository, state: "failed")

    expect(status_for(job)).to eq(:delivery_needs_attention)
  end

  it "resolves to delivery_needs_attention when the job closed without a successful closure reason" do
    job = Factories.job_record(repository: repository, state: "closed", closure_reason: "too_many_failures")

    expect(status_for(job)).to eq(:delivery_needs_attention)
  end

  it "prefers a merged upstream link over an unsuccessful local closure reason" do
    job = Factories.job_record(repository: repository, state: "closed", closure_reason: "preempted")
    JobPrLink.create!(job: job, role: JobPrLink::ROLE_PROMOTION, pr_number: 7, metadata: { "pr_state" => "merged" })

    expect(status_for(job, promotion: true)).to eq(:upstream_merged)
  end

  it "builds its own DeliveryPolicy when none is injected" do
    job = Factories.job_record(repository: repository, state: "implemented")

    expect(described_class.for(job: job)).to eq(:waiting_for_local_approval)
  end
end
