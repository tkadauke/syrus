require "rails_helper"

RSpec.describe "permission presentation copy" do
  it "defines a localized description for every descriptor effect" do
    %w[en de la].each do |locale|
      settings = JSON.parse(Rails.root.join("app/frontend/i18n/locales/#{locale}/settings.json").read)
      copy = settings.dig("permissions", "effect_descriptions")

      expect(copy.keys).to match_array(Permissions::CapabilityDescriptor::EFFECTS.map(&:to_s)),
        "#{locale} permission effect copy must cover the descriptor registry exactly"
      expect(copy.values).to all(be_present)
    end
  end

  it "gives every registered operation human-facing names distinct from its identifiers" do
    Permissions::Catalog.descriptors.each do |descriptor|
      presentation = descriptor.presentation

      expect(presentation.capability_name).to be_present
      expect(presentation.operation_name).to be_present
      expect(presentation.capability_name).not_to eq(descriptor.capability)
      expect(presentation.operation_name).not_to eq(descriptor.operation)
    end
  end
end
