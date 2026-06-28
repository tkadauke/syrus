require "rails_helper"

RSpec.describe GenerateJobTitleJob, type: :job do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) do
    Factories.job_record(
      user: user,
      repository: repository,
      kind: "direct",
      issue_number: nil,
      issue_title: GenerateJobTitleJob::PENDING_TITLE,
      issue_body: "Repair the checkout flow.",
      title_pending: true
    )
  end

  it "sets the generated title, clears the pending flag, and broadcasts" do
    expect(DirectJobTitleGenerator).to receive(:generate).with(
      "Repair the checkout flow.",
      user: user,
      repository: repository,
      agent_provider: job.agent_provider
    ).and_return(DirectJobTitleGenerator::Result.new(title: "Checkout Flow Repair", error: nil))
    expect(AppEvents).to receive(:broadcast).with(
      user: user,
      type: "updated",
      resource: "job",
      id: job.id,
      changed: [ "issue_title", "title_pending" ]
    )

    described_class.perform_now(job)

    job.reload
    expect(job.issue_title).to eq("Checkout Flow Repair")
    expect(job).not_to be_title_pending
  end

  it "sets a fallback title, clears the pending flag, broadcasts, and re-raises on failure" do
    expect(DirectJobTitleGenerator).to receive(:generate).and_return(
      DirectJobTitleGenerator::Result.new(title: nil, error: "provider unavailable")
    )
    expect(AppEvents).to receive(:broadcast).with(
      user: user,
      type: "updated",
      resource: "job",
      id: job.id,
      changed: [ "issue_title", "title_pending" ]
    )

    expect {
      described_class.perform_now(job)
    }.to raise_error(GenerateJobTitleJob::TitleGenerationFailed, "provider unavailable")

    job.reload
    expect(job.issue_title).to eq("Untitled job")
    expect(job).not_to be_title_pending
  end

  it "does nothing when the title is no longer pending" do
    job.update!(issue_title: "Already named", title_pending: false)

    expect(DirectJobTitleGenerator).not_to receive(:generate)

    described_class.perform_now(job)

    expect(job.reload.issue_title).to eq("Already named")
  end
end
