require "rails_helper"

RSpec.describe Permissions::Catalog, :reset_plugin_registry do
  around do |example|
    Syrus::PluginRegistry.reset!
    example.run
    Syrus::PluginRegistry.reset!
  end

  it "collects capabilities and resource schemas from enabled permission providers" do
    provider = permission_provider
    Syrus::PluginRegistry.register(
      name: "permission_example", version: "1.0.0", provides: { permission_provider: provider }
    )

    expect(described_class.descriptors).to include(provider.permission_capability_descriptors.first)
    expect(described_class.resource_scopes).to eq(example_resource: provider.permission_resource_scopes.fetch(:example_resource))
    expect(Permissions::CapabilityRegistryValidator.for_application.registrations)
      .to include(have_attributes(surface: :permission_provider, descriptor: provider.permission_capability_descriptors.first))
  end

  it "rejects ambiguous resource type ownership across providers" do
    first = permission_provider
    second = permission_provider
    Syrus::PluginRegistry.register(
      name: "permission_one", version: "1.0.0", provides: { permission_provider: first }
    )
    Syrus::PluginRegistry.register(
      name: "permission_two", version: "1.0.0", provides: { permission_provider: second }
    )

    expect { described_class.resource_scopes }.to raise_error(ArgumentError, /more than one provider/)
  end

  it "rejects conflicting capability contracts across providers" do
    first = permission_provider
    second = permission_provider(effects: [ :external_write ])
    Syrus::PluginRegistry.register(
      name: "permission_one", version: "1.0.0", provides: { permission_provider: first }
    )
    Syrus::PluginRegistry.register(
      name: "permission_two", version: "1.0.0", provides: { permission_provider: second }
    )

    expect { described_class.descriptors }
      .to raise_error(ArgumentError, /example\.observe\/read@v1.*conflicting contracts/)
  end

  def permission_provider(effects: [ :network_read ])
    Class.new do
      include Syrus::Plugin::PermissionProvider
      register_resource_scope :example_resource
      register_capability(
        capability: "example.observe@v1", operation: "example.observe/read@v1", effects: effects, risk: :low,
        requestable_roles: [ "chat_planner" ], defaults: { chat_planner: :ask }, maximum_autonomy: :job,
        authority_durations: %i[invocation job], resource_scope: :example_resource,
        classifier: ->(arguments) { arguments }, fingerprint_normalizer: ->(arguments) { arguments },
        redactor: ->(arguments) { arguments }
      )
    end
  end
end
