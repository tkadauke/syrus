require "rails_helper"

RSpec.describe Coworkers::ReviewPresentationContributor do
  it "contributes localized accessible target, evidence, audit, and settings components" do
    contributions = described_class.target_editors + described_class.evidence_renderers +
      described_class.audit_renderers + described_class.settings_summaries

    expect(contributions.map { |entry| entry[:target_type] }.uniq).to eq([ "coworker" ])
    expect(contributions).to all(include(:component, :label_key, :description_key, :aria_label_key))
    expect(described_class.translation_namespaces).to eq([ "coworkers" ])
  end
end
