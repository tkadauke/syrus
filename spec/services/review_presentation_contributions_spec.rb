require "rails_helper"

RSpec.describe ReviewPresentationContributions do
  let(:provider) do
    Class.new do
      include Syrus::Plugin::ReviewPresentationContributor
      def self.target_editors = [{ key: "synthetic.target", component: "synthetic/Target", target_type: "synthetic", label_key: "synthetic:target", aria_label_key: "synthetic:target_aria" }]
      def self.audit_renderers = [{ key: "synthetic.audit", component: "synthetic/Audit", aria_label_key: "synthetic:audit_label" }]
      def self.settings_summaries = [{ key: "synthetic.settings", component: "synthetic/Settings", description_key: "synthetic:settings_description", aria_label_key: "synthetic:settings_aria" }]
      def self.translation_namespaces = [ "synthetic" ]
    end
  end

  before { allow(Syrus::PluginRegistry).to receive(:providers_for).with(:review_presentation_contributor).and_return([ provider ]) }

  it "publishes editor, audit, settings, translation, and accessibility metadata" do
    payload = described_class.payload
    expect(payload[:target_editors].first).to include("target_type" => "synthetic", "label_key" => "synthetic:target")
    expect(payload[:audit_renderers].first).to include("aria_label_key" => "synthetic:audit_label")
    expect(payload[:settings_summaries].first).to include("description_key" => "synthetic:settings_description")
    expect(payload[:translation_namespaces]).to eq([ "synthetic" ])
    expect(described_class.frontend_payload.map { |entry| entry["kind"] })
      .to contain_exactly("target_editor", "audit", "settings_summary")
  end

  it "preserves a historical snapshot when its renderer is absent" do
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:review_presentation_contributor).and_return([])
    snapshot = { "renderer" => "synthetic.audit", "payload" => { "label" => "Past review" } }
    expect(described_class.render_audit(snapshot)).to eq(snapshot)
  end
end
