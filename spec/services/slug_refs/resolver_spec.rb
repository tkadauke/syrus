require "rails_helper"

RSpec.describe SlugRefs::Resolver, :reset_plugin_registry do
  before { Syrus::PluginRegistry.reset! }
  after { Syrus::PluginRegistry.reset! }

  it "resolves a plugin-registered slug type without core prefix knowledge" do
    record = Struct.new(:id).new(123)
    plugin_slug_type = Class.new do
      include Syrus::Plugin::SlugType

      define_singleton_method(:prefix) { "NOTE" }
      define_singleton_method(:display_label) { "Note" }
      define_singleton_method(:record_for) { |id, user:| user && id == record.id ? record : nil }
      define_singleton_method(:web_path) { |resolved_record| "/notes/#{resolved_record.id}" }
      define_singleton_method(:api_preview_path) { |resolved_record| "/api/v1/app/notes/#{resolved_record.id}/preview" }
      define_singleton_method(:preview_available?) { true }
    end

    Syrus::PluginRegistry.register(
      name: "notes_slug_fixture",
      version: "1.0.0",
      provides: { slug_type: plugin_slug_type }
    )

    resolution = described_class.resolve("note-123", user: Factories.user)

    expect(resolution).to be_accessible
    expect(resolution.to_h).to include(
      canonical_slug: "NOTE-123",
      type: "note",
      prefix: "NOTE",
      display_label: "Note",
      numeric_id: 123,
      web_path: "/notes/123",
      api_preview_path: "/api/v1/app/notes/123/preview",
      preview_available: true
    )
  end
end
