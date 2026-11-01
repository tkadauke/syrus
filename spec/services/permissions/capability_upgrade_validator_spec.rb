require "rails_helper"

RSpec.describe Permissions::CapabilityUpgradeValidator do
  def descriptor(operation: "example.data/read@v1", **overrides)
    Permissions::CapabilityDescriptor.new(**{
      capability: "example.data@v1",
      operation: operation,
      effects: [ :network_read ],
      risk: :low,
      requestable_roles: [ "chat_planner" ],
      defaults: { chat_planner: :ask },
      maximum_autonomy: :job,
      authority_durations: %i[invocation job],
      maximum_duration: 1.day,
      resource_scope: { type: :example_account, options: { version: 1 } },
      classifier: ->(arguments) { arguments },
      fingerprint_normalizer: ->(arguments) { arguments },
      redactor: ->(arguments) { arguments }
    }.merge(overrides))
  end

  it "accepts a renamed operation when the old key remains an alias" do
    current = descriptor(
      capability: "example.records@v2",
      operation: "example.data/select@v2",
      capability_aliases: [ "example.data@v1" ],
      operation_aliases: [ "example.data/read@v1" ]
    )

    expect(described_class.new(previous: [ descriptor ], current: [ current ]).findings).to be_empty
  end

  it "rejects moving one operation to another capability while its old family remains" do
    previous = [
      descriptor,
      descriptor(operation: "example.data/write@v1")
    ]
    current = [
      descriptor(operation: "example.data/write@v1"),
      descriptor(
        capability: "other.data@v1",
        operation: "other.data/read@v1",
        operation_aliases: [ "example.data/read@v1" ]
      )
    ]

    expect(described_class.new(previous: previous, current: current).findings)
      .to contain_exactly(have_attributes(code: :capability_family_changed))
  end

  it "rejects reuse of an identifier retained in the retired-key ledger" do
    validator = described_class.new(
      previous: [], current: [ descriptor ], retired_identifiers: [ "example.data/read@v1" ]
    )

    expect(validator.findings).to contain_exactly(have_attributes(code: :retired_identifier_reused))
  end

  it "rejects silently dropping an operation identifier" do
    validator = described_class.new(previous: [ descriptor ], current: [])

    expect(validator.findings.map(&:code)).to eq(%i[unaccounted_identifier_removal unaccounted_identifier_removal])
    expect(described_class.new(
      previous: [ descriptor ], current: [],
      retired_identifiers: [ "example.data@v1", "example.data/read@v1" ]
    ).findings).to be_empty
  end

  it "rejects dangling and ambiguous scope migrations" do
    migration = Permissions::CapabilityScopeMigration.new(
      from_operation: "legacy.data/read@v1", to_operation: "example.data/read@v2",
      transform: ->(scope, context:) { scope }
    )
    validator = described_class.new(previous: [ descriptor ], current: [ descriptor ], scope_migrations: [ migration, migration ])

    expect(validator.findings.map(&:code)).to include(
      :ambiguous_scope_migration, :unknown_scope_migration_source, :unknown_scope_migration_target
    )
  end

  it "requires an explicit migration when a successor changes its resource scope schema" do
    current = descriptor(
      operation: "example.data/read@v2",
      operation_aliases: [ "example.data/read@v1" ],
      resource_scope: { type: :example_account, options: { version: 2 } }
    )

    expect(described_class.new(previous: [ descriptor ], current: [ current ]).findings)
      .to contain_exactly(have_attributes(code: :missing_scope_migration))
  end

  it "accepts an explicit scope migration between operation versions" do
    current = descriptor(
      operation: "example.data/read@v2",
      operation_aliases: [ "example.data/read@v1" ],
      resource_scope: { type: :example_account, options: { version: 2 } }
    )
    migration = Permissions::CapabilityScopeMigration.new(
      from_operation: "example.data/read@v1",
      to_operation: "example.data/read@v2",
      transform: ->(scope, context:) { scope.merge("version" => 2) }
    )

    validator = described_class.new(previous: [ descriptor ], current: [ current ], scope_migrations: [ migration ])

    expect(validator.findings).to be_empty
    expect(migration.migrate({ "account_id" => 4 }, context: nil)).to eq("account_id" => 4, "version" => 2)
  end

  it "rejects semantic widening even when the identifier is versioned" do
    current = descriptor(
      operation: "example.data/read@v2",
      operation_aliases: [ "example.data/read@v1" ],
      effects: %i[network_read confidential_read],
      defaults: { chat_planner: :allow },
      maximum_autonomy: :permanent,
      authority_durations: %i[invocation job permanent],
      maximum_duration: nil
    )

    finding = described_class.new(previous: [ descriptor ], current: [ current ]).findings
      .find { |candidate| candidate.code == :semantic_widening }

    expect(finding.message).to include("effects", "maximum autonomy", "authority durations", "maximum duration", "role defaults")
  end

  it "allows a successor to narrow its authorization contract" do
    current = descriptor(
      operation: "example.data/read@v2",
      operation_aliases: [ "example.data/read@v1" ],
      effects: [],
      defaults: { chat_planner: :deny },
      maximum_autonomy: :invocation,
      authority_durations: [ :invocation ],
      maximum_duration: 1.hour
    )

    expect(described_class.new(previous: [ descriptor ], current: [ current ]).findings).to be_empty
  end
end
