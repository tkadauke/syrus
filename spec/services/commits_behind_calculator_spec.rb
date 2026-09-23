require "rails_helper"

RSpec.describe CommitsBehindCalculator do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:head_sha) { "b" * 40 }
  let(:base_sha) { "a" * 40 }

  it "returns nil without touching any provider or the bare clone when a SHA is blank" do
    expect(RepositoryBareClone).not_to receive(:new)

    expect(described_class.call(repository: repository, user: user, head_sha: nil, base_sha: base_sha)).to be_nil
    expect(described_class.call(repository: repository, user: user, head_sha: head_sha, base_sha: "")).to be_nil
  end

  it "prefers a provider's numeric divergence over the bare clone" do
    stub_repository_divergence_provider(behind: 7, ahead: 2)
    expect(RepositoryBareClone).not_to receive(:new)

    distance = described_class.call(repository: repository, user: user, head_sha: head_sha, base_sha: base_sha)

    expect(distance).to eq(7)
  end

  it "falls back to the bare clone when no provider supports divergence" do
    # The default test provider (FakeRepositoryContentProvider) does not
    # implement #divergence, so the chain raises Unsupported.
    fake_clone = instance_double(RepositoryBareClone)
    allow(RepositoryBareClone).to receive(:new).with(repository).and_return(fake_clone)
    allow(fake_clone).to receive(:sync!).with(user: user)
    allow(fake_clone).to receive(:commits_behind).with(head_sha: head_sha, base_sha: base_sha).and_return(12)

    distance = described_class.call(repository: repository, user: user, head_sha: head_sha, base_sha: base_sha)

    expect(distance).to eq(12)
  end

  it "falls back to the bare clone when every provider is unavailable" do
    stub_repository_divergence_provider(behind: 0, error: RepositoryContent::Unavailable.new("outage"))
    fake_clone = instance_double(RepositoryBareClone)
    allow(RepositoryBareClone).to receive(:new).with(repository).and_return(fake_clone)
    allow(fake_clone).to receive(:sync!).with(user: user)
    allow(fake_clone).to receive(:commits_behind).with(head_sha: head_sha, base_sha: base_sha).and_return(4)

    distance = described_class.call(repository: repository, user: user, head_sha: head_sha, base_sha: base_sha)

    expect(distance).to eq(4)
  end

  it "does not mask a bare-clone sync failure once the provider path has already been tried" do
    stub_repository_divergence_provider(behind: 0, error: RepositoryContent::Unavailable.new("outage"))
    allow(RepositoryBareClone).to receive(:new).and_raise(GitRunner::GitError.new([ "fetch" ], 1, "boom"))

    expect {
      described_class.call(repository: repository, user: user, head_sha: head_sha, base_sha: base_sha)
    }.to raise_error(GitRunner::GitError)
  end

  it "treats a provider answer of zero as a real answer, not a miss" do
    stub_repository_divergence_provider(behind: 0)
    expect(RepositoryBareClone).not_to receive(:new)

    expect(described_class.call(repository: repository, user: user, head_sha: head_sha, base_sha: base_sha)).to eq(0)
  end
end
