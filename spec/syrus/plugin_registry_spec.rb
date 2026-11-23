require "rails_helper"

RSpec.describe Syrus::PluginRegistry do
  it "restores enabled bundled agent and chat providers from the boot snapshot" do
    described_class.restore(described_class.boot_snapshot)

    expect(described_class.providers_for(:agent_provider).map(&:provider_key)).to include("claude", "codex", "agy")
    expect(described_class.providers_for(:chat_provider).map(&:provider_key)).to include("claude", "codex", "agy")
  end

  before { described_class.reset! }
  after  { described_class.reset! }

  describe ".register_direct / .providers_for" do
    let(:provider) { double("provider") }

    it "registers a provider under a valid extension point" do
      described_class.register_direct(:preview_provider, provider)
      expect(described_class.providers_for(:preview_provider)).to eq([provider])
    end

    it "accepts extension point as a string" do
      described_class.register_direct("preview_provider", provider)
      expect(described_class.providers_for("preview_provider")).to eq([provider])
    end

    it "returns an empty array when nothing is registered" do
      expect(described_class.providers_for(:preview_provider)).to eq([])
    end

    it "returns a dup so mutations do not corrupt the registry" do
      described_class.register_direct(:preview_provider, provider)
      described_class.providers_for(:preview_provider) << double("intruder")
      expect(described_class.providers_for(:preview_provider)).to eq([provider])
    end

    it "accumulates multiple providers for the same extension point" do
      a = double("a")
      b = double("b")
      described_class.register_direct(:preview_provider, a)
      described_class.register_direct(:preview_provider, b)
      expect(described_class.providers_for(:preview_provider)).to eq([a, b])
    end

    it "keeps extension points isolated from each other" do
      described_class.register_direct(:preview_provider, provider)
      expect(described_class.providers_for(:agent_provider)).to eq([])
    end

    it "raises ArgumentError for an unknown extension point on register" do
      expect { described_class.register_direct(:nonexistent, provider) }
        .to raise_error(ArgumentError, /Unknown extension point: :nonexistent/)
    end

    it "raises ArgumentError for an unknown extension point on providers_for" do
      expect { described_class.providers_for(:nonexistent) }
        .to raise_error(ArgumentError, /Unknown extension point: :nonexistent/)
    end
  end

  describe ".reset!" do
    it "clears all registered providers" do
      described_class.register_direct(:preview_provider, double("provider"))
      described_class.reset!
      expect(described_class.providers_for(:preview_provider)).to eq([])
    end
  end

  describe "EXTENSION_POINTS" do
    it "includes :preview_provider" do
      expect(described_class::EXTENSION_POINTS).to include(:preview_provider)
    end

    it "includes all expected extension points" do
      expect(described_class::EXTENSION_POINTS).to include(
        :agent_provider, :chat_provider, :mcp_tool_set, :input_source,
        :artifact_renderer, :preview_provider,
        :admin_page, :sidebar_page, :chat_mcp_tool_set, :source_control_provider
      )
    end

    it "no longer lists the Review and Policy points, which are family capabilities" do
      expect(described_class::EXTENSION_POINTS).not_to include(
        :review_gate, :reviewer_target_provider, :review_context_contributor,
        :review_presentation_contributor, :post_implementation_review_provider,
        :diff_review_annotation_provider, :adjudicator, :job_visibility_restriction, :repository_filter
      )
    end
  end

  describe "removed Review and Policy extension points" do
    %i[
      review_gate reviewer_target_provider review_context_contributor review_presentation_contributor
      post_implementation_review_provider diff_review_annotation_provider adjudicator
      job_visibility_restriction repository_filter
    ].each do |point|
      it "rejects a legacy registration of #{point} with a clear error" do
        expect {
          described_class.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "obsolete_#{point}", version: "1.0.0", provides: { point => Class.new })
        }.to raise_error(Syrus::PluginRegistry::RegistrationError, /Unknown extension point :#{point}/)
      end

      it "refuses to look up #{point} through the legacy registry" do
        expect { described_class.providers_for(point) }.to raise_error(ArgumentError, /Unknown extension point/)
      end
    end
  end

  describe "chat identity provider validation" do
    it "requires manifest providers to include the identity interface" do
      expect {
        described_class.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
          name: "bad_chat_identity",
          version: "1.0.0",
          provides: { chat_identity_provider: Class.new }
        )
      }.to raise_error(
        Syrus::PluginRegistry::RegistrationError,
        /must include Syrus::Plugin::ChatIdentityProvider/
      )
    end
  end
end
