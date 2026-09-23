require "rails_helper"

RSpec.describe GitMirror::WorkspaceGitTransport do
  let(:endpoint) { "http://git-mirror:8080" }
  let(:repository) { Factories.repository }
  let(:token) { GitMirror::Configuration.token }

  # An upstream that can hand the mirror credentials, as a hosting plugin would.
  let(:upstream) do
    Class.new do
      include Syrus::Plugin::RepositoryContentProvider

      def self.provider_key = "host"
      def self.display_name = "Host"
      def self.role = :upstream
      def self.available_for?(_repository) = true
      def self.upstream_source(**) = nil
    end
  end

  before do
    allow(PluginRuntime::Services).to receive(:endpoint_for).with("git-mirror").and_return(endpoint)
    RepositoryContent.provider_classes_override = [ GitMirror::ContentProvider, upstream ]
  end

  describe ".available_for?" do
    it "delegates to ContentProvider, the same availability check the JSON reads use" do
      expect(described_class.available_for?(repository)).to be(true)

      RepositoryContent.provider_classes_override = [ GitMirror::ContentProvider ]
      expect(described_class.available_for?(repository)).to be(false)
    end
  end

  describe ".build" do
    it "returns nil when the mirror service isn't reachable" do
      allow(PluginRuntime::Services).to receive(:endpoint_for).with("git-mirror").and_return(nil)

      expect(described_class.build(repository: repository, user: repository.user)).to be_nil
    end

    it "returns an instance bound to the mirror's endpoint otherwise" do
      instance = described_class.build(repository: repository, user: repository.user)

      expect(instance).to be_a(described_class)
    end
  end

  describe "#url" do
    it "is the repository's smart-HTTP route, with no credential in it" do
      instance = described_class.build(repository: repository, user: repository.user)

      expect(instance.url).to eq("#{endpoint}/v1/repositories/#{repository.id}")
    end
  end

  describe "#env" do
    it "carries the bearer token as an http.extraHeader, never in the URL" do
      instance = described_class.build(repository: repository, user: repository.user)

      expect(instance.env).to eq(
        "GIT_CONFIG_COUNT" => "1",
        "GIT_CONFIG_KEY_0" => "http.extraHeader",
        "GIT_CONFIG_VALUE_0" => "Authorization: Bearer #{token}"
      )
    end
  end

  describe "#register!" do
    let(:source) { RepositoryContent::Source.new(vcs: "git", url: "https://example.test/r.git", password: "short-lived") }

    it "registers the repository with the mirror when an upstream can supply a source" do
      allow(RepositoryContent).to receive(:upstream_source_for).with(repository).and_return(source)
      register = stub_request(:put, "#{endpoint}/v1/repositories/#{repository.id}")
        .with(body: hash_including("url" => "https://example.test/r.git"), headers: { "Authorization" => "Bearer #{token}" })
        .to_return(status: 200, body: "{}")

      described_class.build(repository: repository, user: repository.user).register!

      expect(register).to have_been_requested.once
    end

    it "does nothing when there is no upstream to register with" do
      allow(RepositoryContent).to receive(:upstream_source_for).with(repository).and_return(nil)

      expect { described_class.build(repository: repository, user: repository.user).register! }.not_to raise_error
    end
  end
end
