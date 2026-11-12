require "rails_helper"

RSpec.describe "permission presentation copy" do
  it "requires descriptor registries and the compatibility adapter to declare presentation copy" do
    sources = %w[
      execution_actions ingestion_actions coworker_actions local_mode_actions
      job_lifecycle operational_actions effect_actions capability_descriptor_adapter
    ]

    sources.each do |source|
      body = Rails.root.join("app/services/permissions/#{source}.rb").read
      declarations = body.scan(/CapabilityDescriptor\.new\((.*?)\n\s*\)/m)

      expect(declarations).not_to be_empty
      expect(declarations.flatten).to all(include("presentation:")),
        "#{source} must declare presentation copy for every descriptor"
    end
  end

  it "defines a localized name and description for every descriptor effect" do
    %w[en de la].each do |locale|
      settings = JSON.parse(Rails.root.join("app/frontend/i18n/locales/#{locale}/settings.json").read)
      descriptions = settings.dig("permissions", "effect_descriptions")
      names = settings.dig("permissions", "effect_names")

      expect(descriptions.keys).to match_array(Permissions::CapabilityDescriptor::EFFECTS.map(&:to_s)),
        "#{locale} permission effect copy must cover the descriptor registry exactly"
      expect(names.keys).to match_array(Permissions::CapabilityDescriptor::EFFECTS.map(&:to_s)),
        "#{locale} permission effect names must cover the descriptor registry exactly"
      expect(descriptions.values).to all(be_present)
      expect(names.values).to all(be_present)
    end
  end

  it "gives every registered operation human-facing names distinct from its identifiers" do
    Permissions::Catalog.descriptors.each do |descriptor|
      presentation = descriptor.presentation

      expect(presentation.capability_name).to be_present
      expect(presentation.capability_description).to be_present
      expect(presentation.operation_name).to be_present
      expect(presentation.operation_description).to be_present
      expect(presentation.capability_name).not_to eq(descriptor.capability)
      expect(presentation.operation_name).not_to eq(descriptor.operation)
    end
  end
end
