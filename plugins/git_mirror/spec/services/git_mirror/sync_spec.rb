require "rails_helper"

RSpec.describe GitMirror::Sync do
  let(:endpoint) { "http://git-mirror:8080" }
  let!(:repository) { Factories.repository }
  let(:source) do
    RepositoryContent::Source.new(vcs: "git", url: "https://example.test/#{repository.slug}.git",
                                  username: "x-access-token", password: "short-lived", expires_at: Time.utc(2026, 9, 21, 13))
  end

  before do
    allow(PluginRuntime::Services).to receive(:endpoint_for).with("git-mirror").and_return(endpoint)
    allow(RepositoryContent).to receive(:upstream_source_for).and_return(nil)
    allow(RepositoryContent).to receive(:upstream_source_for).with(repository).and_return(source)
  end

  def stub_list(ids)
    stub_request(:get, "#{endpoint}/v1/repositories")
      .to_return(status: 200, body: { repositories: ids.map { |id| { id: id } } }.to_json, headers: { "Content-Type" => "application/json" })
  end

  it "registers each active repository with a fresh credential" do
    register = stub_request(:put, "#{endpoint}/v1/repositories/#{repository.id}")
      .with(body: { vcs: "git", url: source.url, username: "x-access-token", password: "short-lived", expires_at: "2026-09-21T13:00:00Z" }.to_json)
      .to_return(status: 200, body: "{}")
    stub_list([ repository.id.to_s ])

    result = described_class.run!

    expect(register).to have_been_requested
    expect(result.registered).to include(repository.id)
  end

  it "removes mirrors of repositories Syrus no longer works on, and nothing else" do
    stub_request(:put, %r{#{endpoint}/v1/repositories/\d+}).to_return(status: 200, body: "{}")
    stub_list([ repository.id.to_s, "999999" ])
    remove = stub_request(:delete, "#{endpoint}/v1/repositories/999999").to_return(status: 204)

    expect(described_class.run!.removed).to eq([ "999999" ])
    expect(remove).to have_been_requested
  end

  it "processes a bounded page and resumes from a durable cursor" do
    stub_const("GitMirror::Sync::BATCH_SIZE", 2)
    repositories = [ repository, Factories.repository, Factories.repository ].sort_by(&:id)
    allow(RepositoryContent).to receive(:upstream_source_for).and_return(source)
    register = stub_request(:put, %r{#{endpoint}/v1/repositories/\d+}).to_return(status: 200, body: "{}")

    first = described_class.run!

    expect(first.registered).to eq(repositories.first(2).map(&:id))
    expect(first.removed).to eq([])
    expect(register).to have_been_requested.times(2)
    expect(PluginRecord.find_by!(name: "git_mirror").config.fetch("sync_repository_cursor")).to eq(repositories.second.id)

    stub_list(repositories.map { |repo| repo.id.to_s })
    second = described_class.run!

    expect(second.registered).to eq([ repositories.last.id ])
    expect(register).to have_been_requested.times(3)
    expect(PluginRecord.find_by!(name: "git_mirror").config).not_to have_key("sync_repository_cursor")
  end

  it "filters inactive and non-git repositories in SQL" do
    archived = Factories.repository(archived_at: Time.current)
    non_git = Factories.repository(vcs: "mercurial")
    register = stub_request(:put, %r{#{endpoint}/v1/repositories/\d+}).to_return(status: 200, body: "{}")
    stub_list([ repository.id.to_s ])

    result = described_class.run!

    expect(result.registered).to eq([ repository.id ])
    expect(register).to have_been_requested.once
    expect(RepositoryContent).not_to have_received(:upstream_source_for).with(archived)
    expect(RepositoryContent).not_to have_received(:upstream_source_for).with(non_git)
  end

  it "does not prune stale mirrors until a complete inventory pass" do
    stub_const("GitMirror::Sync::BATCH_SIZE", 1)
    Factories.repository
    stub_request(:put, %r{#{endpoint}/v1/repositories/\d+}).to_return(status: 200, body: "{}")
    list = stub_list([ repository.id.to_s, "999999" ])

    expect(described_class.run!.removed).to eq([])
    expect(list).not_to have_been_requested

    remove = stub_request(:delete, "#{endpoint}/v1/repositories/999999").to_return(status: 204)
    expect(described_class.run!.removed).to eq([ "999999" ])
    expect(remove).to have_been_requested
  end

  # A blip must not read as licence to throw a mirror away.
  it "keeps the mirror of a repository whose registration failed" do
    stub_request(:put, "#{endpoint}/v1/repositories/#{repository.id}").to_return(status: 503, body: { error: { code: "unavailable" } }.to_json)
    stub_list([ repository.id.to_s ])

    result = described_class.run!

    expect(result.failed).to include(repository.id)
    expect(result.removed).to eq([])
  end

  it "removes nothing when the mirror cannot be listed" do
    stub_request(:put, %r{#{endpoint}/v1/repositories/\d+}).to_return(status: 200, body: "{}")
    stub_request(:get, "#{endpoint}/v1/repositories").to_raise(Errno::ECONNREFUSED)

    expect(described_class.run!.removed).to eq([])
  end

  it "does nothing while the service is not available" do
    allow(PluginRuntime::Services).to receive(:endpoint_for).with("git-mirror").and_return(nil)

    expect(described_class.run!).to be_nil
  end

  it "never lets a failing tick raise" do
    allow(described_class).to receive(:run!).and_raise(StandardError, "boom")

    expect { GitMirror::Callbacks.on_tick }.not_to raise_error
  end
end
