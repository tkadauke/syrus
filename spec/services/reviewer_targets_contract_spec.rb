require "rails_helper"

RSpec.describe ReviewerTargets do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:provider) do
    Class.new do
      include Syrus::Plugin::ReviewerTargetProvider
      def self.target_type = "synthetic"
      def self.options(user:, repository: nil) = []
      def self.resolve(reference:, owner:, repository:)
        { type: target_type, reference:, display: { name: "Synthetic #{reference}" }, available: reference != "revoked" }
      end
      def self.available?(resolution:, **) = resolution.fetch(:available)
      def self.uniqueness_key(resolution:) = "synthetic:#{resolution.fetch(:reference).downcase}"
      def self.audit_snapshot(resolution:) = resolution.fetch(:display).merge(state: "pinned")
    end
  end

  before do
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:reviewer_target_provider).and_return([ provider ])
  end

  it "stores only an opaque reference, uniqueness key, and audit-safe snapshot" do
    expect(described_class.snapshot({ type: "synthetic", reference: "One" }, owner:, repository:)).to eq(
      "type" => "synthetic", "reference" => "One", "uniqueness_key" => "synthetic:one",
      "display" => { "name" => "Synthetic One", "state" => "pinned" }
    )
  end

  it "rejects unavailable and duplicate panel members" do
    expect { described_class.snapshot({ type: "synthetic", reference: "revoked" }, owner:, repository:) }
      .to raise_error(ReviewerTargets::TargetUnavailable)
    expect {
      described_class.validate_panel!([{ type: "synthetic", reference: "ONE" }, { type: "synthetic", reference: "one" }], owner:, repository:)
    }.to raise_error(ReviewerTargets::DuplicateTarget)
  end

  it "fails closed when the provider is absent" do
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:reviewer_target_provider).and_return([])
    expect { described_class.resolve({ type: "synthetic", reference: "one" }, owner:, repository:) }
      .to raise_error(ReviewerTargets::PluginUnavailable)
  end
end
