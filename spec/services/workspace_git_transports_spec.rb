require "rails_helper"

RSpec.describe WorkspaceGitTransports do
  let(:repository) { Factories.repository }
  let(:user) { repository.user }

  def stub_transport(available:, instance: nil)
    Class.new do
      include Syrus::Plugin::WorkspaceGitTransport

      define_singleton_method(:available_for?) { |_repository| available }
      define_singleton_method(:build) { |repository:, user:| instance }
    end
  end

  describe ".for" do
    it "returns nil when no provider is registered" do
      expect(described_class.for(repository, user: user)).to be_nil
    end

    it "returns the first available provider's built instance" do
      built = Object.new
      provider = stub_transport(available: true, instance: built)
      Syrus::PluginRegistry.register(:workspace_git_transport, provider)

      expect(described_class.for(repository, user: user)).to equal(built)
    end

    it "skips a provider that declares itself unavailable for the repository" do
      unavailable = stub_transport(available: false, instance: Object.new)
      Syrus::PluginRegistry.register(:workspace_git_transport, unavailable)

      expect(described_class.for(repository, user: user)).to be_nil
    end

    it "skips a provider that has nothing to build even though it is available" do
      nothing_to_build = stub_transport(available: true, instance: nil)
      built = Object.new
      fallback = stub_transport(available: true, instance: built)
      Syrus::PluginRegistry.register(:workspace_git_transport, nothing_to_build)
      Syrus::PluginRegistry.register(:workspace_git_transport, fallback)

      expect(described_class.for(repository, user: user)).to equal(built)
    end

    it "swallows a provider that raises and moves on rather than blowing up the caller" do
      broken = Class.new do
        include Syrus::Plugin::WorkspaceGitTransport

        def self.available_for?(_repository) = raise("boom")
        def self.build(repository:, user:) = raise("unreachable")
      end
      built = Object.new
      fallback = stub_transport(available: true, instance: built)
      Syrus::PluginRegistry.register(:workspace_git_transport, broken)
      Syrus::PluginRegistry.register(:workspace_git_transport, fallback)

      expect(described_class.for(repository, user: user)).to equal(built)
    end

    it "returns nil without touching the registry when there is no repository" do
      expect(described_class.for(nil, user: user)).to be_nil
    end
  end
end
