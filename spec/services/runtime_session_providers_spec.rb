require "rails_helper"

RSpec.describe RuntimeSessionProviders do
  let(:stub_provider) do
    Class.new do
      include Syrus::Plugin::RuntimeSessionProvider

      def self.provider_key = "stub"
      def self.display_name = "Stub"
      def self.detect(repository, _config) = repository == :matching_repo
      def self.capabilities(_repository, _config) = { stream: "none" }

      def start_session(workspace_ref, _config) = { workspace_ref: workspace_ref }
      def build_or_reload(_session_id, _options) = true
      def launch(_session_id, _options) = true
      def snapshot(_session_id, _options) = nil
      def inspect(_session_id = nil, _options = nil) = {}
      def input(_session_id, _event) = true
      def logs(_session_id, _cursor, _options) = []
      def stop_session(_session_id) = true
    end
  end

  before do
    Syrus::PluginRegistry.register(:runtime_session_provider, stub_provider)
  end

  after { Syrus::PluginRegistry.reset! }

  describe ".all" do
    it "includes registered runtime session providers" do
      expect(described_class.all).to include(stub_provider)
    end
  end

  describe ".for" do
    it "returns the registered provider class for a known provider_key" do
      expect(described_class.for("stub")).to eq(stub_provider)
    end

    it "raises a configuration error for an unknown provider_key" do
      expect { described_class.for("nonexistent") }
        .to raise_error(RuntimeSessionProviders::ConfigurationError, /Unknown runtime session provider/)
    end
  end

  describe ".detect_for" do
    it "returns the first provider whose class-level detect matches" do
      expect(described_class.detect_for(:matching_repo)).to eq(stub_provider)
    end

    it "returns nil when no provider detects the repository" do
      expect(described_class.detect_for(:other_repo)).to be_nil
    end
  end
end
