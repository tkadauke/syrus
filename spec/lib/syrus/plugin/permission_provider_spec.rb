require "rails_helper"

RSpec.describe Syrus::Plugin::PermissionProvider do
  let(:provider) do
    Class.new do
      include Syrus::Plugin::PermissionProvider

      register_resource_scope(
        :example_account,
        normalize: ->(scope, context:) { { id: Integer(scope.fetch(:id)) } },
        label: ->(scope, context:) { "Account #{scope.fetch('id')}" }
      )

      register_capability(
        capability: "example.records@v1",
        operation: "example.records/read@v1",
        effects: %i[network_read confidential_read],
        risk: :medium,
        requestable_roles: %w[chat_planner coworker],
        defaults: { chat_planner: :allow, coworker: :ask },
        maximum_autonomy: :job,
        authority_durations: %i[invocation chat_session job],
        maximum_duration: 1.day,
        resource_scope: :example_account,
        classifier: ->(_arguments) { { operation: "example.records/read@v1" } },
        fingerprint_normalizer: ->(arguments) { arguments },
        redactor: ->(arguments) { arguments.except(:secret) }
      )
    end
  end

  it "registers reusable resource schemas and complete capability contracts" do
    descriptor = provider.capability_descriptor("example.records/read@v1")

    expect(descriptor.resource_scope).to equal(provider.permission_resource_scopes.fetch(:example_account))
    expect(descriptor.effects).to eq(%i[network_read confidential_read])
    expect(descriptor.requestable_roles).to eq(%w[chat_planner coworker])
    expect(descriptor.maximum_autonomy).to eq(:job)
    expect(descriptor.authority_durations).to eq(%i[invocation chat_session job])
    expect(descriptor.classify({})).to include(operation: "example.records/read@v1")
    expect(descriptor.normalize_fingerprint(query: "select 1")).to eq(query: "select 1")
    expect(descriptor.redact(secret: "hidden", query: "select 1")).to eq(query: "select 1")
    expect(provider.permission_capability_descriptors).to be_frozen
    expect(provider.permission_resource_scopes).to be_frozen
  end

  it "rejects duplicate scopes, duplicate operations, and unknown scope references" do
    expect { provider.register_resource_scope(:example_account) }
      .to raise_error(ArgumentError, /already registered/)
    expect { provider.register_capability(**provider.capability_descriptor("example.records/read@v1").to_h) }
      .to raise_error(ArgumentError, /already registered/)
    expect { provider.register_capability(**capability_attributes(resource_scope: :missing)) }
      .to raise_error(KeyError)
  end

  it "registers scope migrations and validates upgrades through the public provider API" do
    migration = provider.migrate_permission_scope(
      from_operation: "legacy.records/read@v1",
      to_operation: "example.records/read@v1",
      with: ->(scope, context:) { scope }
    )

    expect(provider.permission_scope_migrations).to contain_exactly(migration)
    expect(provider.permission_scope_migrations).to be_frozen
    expect { provider.migrate_permission_scope(
      from_operation: "legacy.records/read@v1",
      to_operation: "example.records/read@v1",
      with: ->(scope, context:) { scope }
    ) }.to raise_error(ArgumentError, /already registered/)
    provider.retire_permission_identifier("example.records/read@v1")
    expect(provider.retired_permission_identifiers).to eq([ "example.records/read@v1" ])
    expect { provider.validate_permission_upgrade!(previous_descriptors: []) }
      .to raise_error(Permissions::CapabilityUpgradeValidator::ValidationError, /retired capability identifier/)
  end

  def capability_attributes(resource_scope:)
    {
      capability: "other.records@v1", operation: "other.records/read@v1", effects: [ :network_read ], risk: :low,
      requestable_roles: [ "chat_planner" ], defaults: { chat_planner: :ask }, maximum_autonomy: :invocation,
      authority_durations: [ :invocation ], resource_scope: resource_scope, classifier: ->(arguments) { arguments },
      fingerprint_normalizer: ->(arguments) { arguments }, redactor: ->(arguments) { arguments }
    }
  end
end
