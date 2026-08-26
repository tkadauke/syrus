require "rails_helper"

RSpec.describe UpstreamExportDispatchJob do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, issue_number: 1) }

  it "delegates to UpstreamExportDispatcher for the loaded job" do
    expect(UpstreamExportDispatcher).to receive(:call!).with(job)

    described_class.new.perform(job.id)
  end

  it "is a no-op when the job no longer exists" do
    expect(UpstreamExportDispatcher).not_to receive(:call!)

    expect { described_class.new.perform(-1) }.not_to raise_error
  end
end
