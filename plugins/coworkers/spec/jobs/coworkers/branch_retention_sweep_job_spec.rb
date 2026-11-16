require "rails_helper"

RSpec.describe Coworkers::BranchRetentionSweepJob do
  it "sweeps later coworkers before retrying an isolated failure" do
    owner = Factories.user
    repository = Factories.repository(user: owner)
    first = Coworkers::Coworker.create!(owner_user: owner, name: "First", handle: "first-sweep",
      workspace_repo: repository.remote_url)
    second = Coworkers::Coworker.create!(owner_user: owner, name: "Second", handle: "second-sweep",
      workspace_repo: repository.remote_url)
    failure = GitRunner::GitError.new([ "fetch" ], 1, "temporarily unavailable")
    allow(Coworkers::BranchRetentionSweep).to receive(:call).with(coworker: first, limit: 50).and_raise(failure)
    allow(Coworkers::BranchRetentionSweep).to receive(:call).with(coworker: second, limit: 50).and_return(0)

    expect { described_class.new.perform }.to raise_error(failure)
    expect(Coworkers::BranchRetentionSweep).to have_received(:call).with(coworker: second, limit: 50)
  end
end
