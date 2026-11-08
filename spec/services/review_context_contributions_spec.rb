require "rails_helper"

RSpec.describe ReviewContextContributions do
  let(:provider) do
    Class.new do
      include Syrus::Plugin::ReviewContextContributor
      def self.target_type = "synthetic"
      def self.prepare(target:, **) = { manifest: { files: [ "safe.md" ] }, restricted_text: "secret context", persistence_token: target.fetch("reference") }
      def self.persist(target:, **) = { owner: "synthetic", type: "journal", key: target.fetch("reference"), version: 1, persisted_at: Time.current.iso8601 }
    end
  end

  before { allow(Syrus::PluginRegistry).to receive(:providers_for).with(:review_context_contributor).and_return([ provider ]) }

  it "separates the safe manifest from restricted exact text and returns an opaque receipt" do
    context = described_class.prepare(target: { type: "synthetic", reference: "7" }, run: nil, evidence: nil, criteria: [])
    expect(context).to include("manifest" => { "files" => [ "safe.md" ] }, "restricted_text" => "secret context")
    expect(context).to be_frozen
    expect(described_class.persist(target: { type: "synthetic", reference: "7" }, run: nil, context:, verdict: "approved", update: {}))
      .to include("owner" => "synthetic", "key" => "7", "version" => 1)
  end

  it "fails closed when a disabled or unhealthy provider is withheld" do
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:review_context_contributor).and_return([])
    expect { described_class.prepare(target: { type: "synthetic" }, run: nil, evidence: nil, criteria: []) }
      .to raise_error(described_class::Unavailable)
  end

  it "rejects oversized restricted prompt text" do
    allow(provider).to receive(:prepare).and_return(
      manifest: {}, restricted_text: "x" * (described_class::MAX_RESTRICTED_TEXT_BYTES + 1)
    )
    expect { described_class.prepare(target: { type: "synthetic" }, run: nil, evidence: nil, criteria: []) }
      .to raise_error(ArgumentError, /too large/)
  end

  describe ".target_for" do
    let(:provider) do
      Class.new do
        include Syrus::Plugin::ReviewContextContributor
        def self.target_type = "fake"
        def self.legacy_target(reviewer) = reviewer == :owned ? { type: "fake", reference: "1" } : nil
      end
    end

    before { allow(Syrus::PluginRegistry).to receive(:providers_for).with(:review_context_contributor).and_return([ provider ]) }

    it "prefers the target stored on the step" do
      stored = { "type" => "fake", "reference" => "9" }
      expect(described_class.target_for(step_target: stored, reviewer: :owned)).to eq(stored)
    end

    it "maps a historical reviewer to an opaque stringified target" do
      expect(described_class.target_for(step_target: nil, reviewer: :owned)).to eq("type" => "fake", "reference" => "1")
    end

    it "returns nil when no provider claims the reviewer (plugin absent) or there is no reviewer" do
      expect(described_class.target_for(step_target: nil, reviewer: :other)).to be_nil
      expect(described_class.target_for(step_target: nil, reviewer: nil)).to be_nil
    end
  end
end
