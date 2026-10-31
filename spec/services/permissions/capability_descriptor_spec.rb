require "rails_helper"

RSpec.describe Permissions::CapabilityDescriptor do
  def attributes
    {
      capability: "mysql.data@v1",
      operation: "mysql.data/read@v1",
      effects: %i[network_read confidential_read],
      risk: :medium,
      requestable_roles: %w[chat_planner coworker],
      defaults: { chat_planner: :allow, coworker: :ask },
      maximum_autonomy: :job,
      authority_durations: %i[invocation chat_session job],
      maximum_duration: 1.day,
      resource_scope: { type: :mysql_database },
      classifier: ->(_arguments) { { operation: "mysql.data/read@v1" } },
      fingerprint_normalizer: ->(arguments) { arguments },
      redactor: ->(_arguments) { {} }
    }
  end

  it "captures the complete immutable provider contract" do
    descriptor = described_class.new(**attributes)

    expect(descriptor).to be_frozen
    expect(descriptor.capability).to eq("mysql.data@v1")
    expect(descriptor.operation).to eq("mysql.data/read@v1")
    expect(descriptor.resource_scope.type).to eq(:mysql_database)
    expect(descriptor.defaults).to eq("chat_planner" => :allow, "coworker" => :ask)
    expect(descriptor.authority_durations).to eq(%i[invocation chat_session job])
  end

  it "requires versioned capability and operation identifiers" do
    expect { described_class.new(**attributes.merge(capability: "mysql.data")) }
      .to raise_error(ArgumentError, /versioned identifier/)
    expect { described_class.new(**attributes.merge(operation: "mysql.data/read")) }
      .to raise_error(ArgumentError, /versioned identifier/)
  end

  it "accepts only distinct, versioned aliases that do not reuse the canonical key" do
    descriptor = described_class.new(**attributes.merge(
      capability_aliases: [ "mysql.records@v1" ],
      operation_aliases: [ "mysql.records/select@v1" ]
    ))

    expect(descriptor.capability_aliases).to eq([ "mysql.records@v1" ])
    expect(descriptor.operation_aliases).to eq([ "mysql.records/select@v1" ])
    expect { described_class.new(**attributes.merge(capability_aliases: [ "mysql.data" ])) }
      .to raise_error(ArgumentError, /versioned identifier/)
    expect { described_class.new(**attributes.merge(capability_aliases: [ "mysql.data@v1" ])) }
      .to raise_error(ArgumentError, /canonical identifier/)
    expect { described_class.new(**attributes.merge(operation_aliases: [ "old.read@v1", "old.read@v1" ])) }
      .to raise_error(ArgumentError, /duplicates/)
  end

  it "requires an explicit default for every requestable role" do
    expect { described_class.new(**attributes.merge(defaults: { chat_planner: :allow })) }
      .to raise_error(ArgumentError, /missing role defaults: coworker/)
  end

  it "rejects unknown effects and non-callable hooks" do
    expect { described_class.new(**attributes.merge(effects: [ :surprise ])) }
      .to raise_error(ArgumentError, /unknown effects/)
    expect { described_class.new(**attributes.merge(redactor: nil)) }
      .to raise_error(ArgumentError, /redactor must respond to call/)
  end
end

RSpec.describe Permissions::CapabilityDescriptorAdapter do
  it "provides deterministic normalization and secret redaction for legacy definitions" do
    descriptor = described_class.for_plugin_definition(name: "execute_query", mutation: true)
    arguments = { "z" => 1, "password" => "secret", "nested" => { "api_key" => "key", "a" => 2 } }

    expect(descriptor.capability).to eq("execute_query@v1")
    expect(descriptor.operation).to eq("execute_query/execute_query@v1")
    expect(descriptor.effects).to eq([ :internal_write ])
    expect(descriptor.normalize_fingerprint(arguments).keys).to eq(%w[nested password z])
    expect(descriptor.redact(arguments)).to include("password" => "[REDACTED]", "nested" => include("api_key" => "[REDACTED]"))
  end

  it "adapts MCP-valid tool names that cannot begin canonical identifiers" do
    %w[1password _private -hidden .internal].each do |tool_name|
      descriptor = described_class.for_plugin_definition(name: tool_name)

      expect(descriptor.capability).to eq("legacy.#{tool_name}@v1")
      expect(descriptor.operation).to eq("legacy.#{tool_name}/legacy.#{tool_name}@v1")
    end
  end

  it "accepts an explicit canonical descriptor from a plugin definition" do
    explicit = Permissions::CapabilityDescriptor.new(**{
      capability: "plugin.observe@v2", operation: "plugin.observe/read@v3", effects: [ :network_read ], risk: :low,
      requestable_roles: [ "chat_planner" ], defaults: { chat_planner: :allow }, maximum_autonomy: :permanent,
      authority_durations: [ :permanent ], resource_scope: { type: :account }, classifier: ->(args) { args },
      fingerprint_normalizer: ->(args) { args }, redactor: ->(args) { args }
    })

    expect(described_class.for_plugin_definition(name: "observe", capability_descriptor: explicit)).to equal(explicit)
  end
end
