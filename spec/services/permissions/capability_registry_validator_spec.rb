require "rails_helper"

RSpec.describe Permissions::CapabilityRegistryValidator do
  def descriptor(capability: "example.data@v1", operation: "example.data/read@v1", **overrides)
    Permissions::CapabilityDescriptor.new(**{
      capability: capability,
      operation: operation,
      effects: [ :network_read ],
      risk: :low,
      requestable_roles: [ "chat_planner" ],
      defaults: { chat_planner: :allow },
      maximum_autonomy: :permanent,
      authority_durations: [ :invocation ],
      resource_scope: { type: :none },
      classifier: ->(arguments) { arguments },
      fingerprint_normalizer: ->(arguments) { arguments },
      redactor: ->(arguments) { arguments }
    }.merge(overrides))
  end

  def registration(name, descriptor:, surface: :chat, source: "ExamplePlugin", explicit_descriptor: descriptor.present?)
    described_class::Registration.new(
      tool_name: name, surface: surface, source: source, descriptor: descriptor,
      explicit_descriptor: explicit_descriptor
    )
  end

  it "rejects missing descriptors with an actionable provider and tool diagnostic" do
    validator = described_class.new([ registration("read_example", descriptor: nil) ])

    expect { validator.validate! }.to raise_error(described_class::ValidationError, /ExamplePlugin chat tool "read_example" has no explicit capability_descriptor/)
  end

  it "rejects compatibility descriptors outside the frozen migration baseline" do
    validator = described_class.new([
      registration("read_example", descriptor: descriptor, explicit_descriptor: false)
    ])

    expect(validator.findings.map(&:code)).to include(:missing_descriptor)
  end

  it "rejects conflicting mappings for the same surface tool" do
    registrations = [
      registration("read_example", descriptor: descriptor),
      registration("read_example", descriptor: descriptor(operation: "example.data/list@v1"), source: "OtherPlugin")
    ]

    expect(described_class.new(registrations).findings.map(&:code)).to include(:conflicting_tool_mapping)
  end

  it "accepts duplicate registrations with the same mapping and contract" do
    registrations = [
      registration("read_example", descriptor: descriptor),
      registration("read_example", descriptor: descriptor, source: "OtherPlugin")
    ]

    expect(described_class.new(registrations).findings).to be_empty
  end

  it "does not report conflicts between compatibility descriptors" do
    registrations = [
      registration("read_example", descriptor: descriptor, explicit_descriptor: false),
      registration("read_example", descriptor: descriptor(
        capability: "other.data@v1", operation: "other.data/read@v1"
      ), source: "OtherPlugin", explicit_descriptor: false)
    ]

    conflict_codes = described_class.new(registrations).findings.map(&:code) &
      %i[conflicting_tool_mapping conflicting_descriptor]
    expect(conflict_codes).to be_empty
  end

  it "rejects aliases claimed by multiple canonical identifiers" do
    registrations = [
      registration("read_example", descriptor: descriptor(capability_aliases: [ "legacy.data@v1" ])),
      registration("write_example", descriptor: descriptor(
        capability: "other.data@v1",
        operation: "other.data/write@v1",
        capability_aliases: [ "legacy.data@v1" ]
      ))
    ]

    finding = described_class.new(registrations).findings.find { |candidate| candidate.code == :conflicting_identifier }
    expect(finding.message).to include("legacy.data@v1", "example.data@v1", "other.data@v1")
  end

  it "rejects an alias that claims another descriptor's canonical identifier" do
    registrations = [
      registration("read_example", descriptor: descriptor),
      registration("read_other", descriptor: descriptor(
        capability: "other.data@v1",
        operation: "other.data/read@v1",
        capability_aliases: [ "example.data@v1" ]
      ))
    ]

    expect(described_class.new(registrations).findings.map(&:code)).to include(:conflicting_identifier)
  end

  it "rejects conflicting policy and effect contracts for one operation" do
    registrations = [
      registration("read_example", descriptor: descriptor),
      registration("read_example_elsewhere", descriptor: descriptor(effects: [ :confidential_read ]), source: "OtherPlugin")
    ]

    finding = described_class.new(registrations).findings.find { |candidate| candidate.code == :conflicting_descriptor }
    expect(finding.message).to include("example.data/read@v1", "ExamplePlugin", "OtherPlugin")
  end

  it "treats eligible roles and defaults as part of the operation contract" do
    registrations = [
      registration("read_example", descriptor: descriptor),
      registration("read_example_elsewhere", descriptor: descriptor(
        requestable_roles: [ "coworker" ], defaults: { coworker: :ask }
      ), source: "OtherPlugin")
    ]

    expect(described_class.new(registrations).findings.map(&:code)).to include(:conflicting_descriptor)
  end

  it "builds application registrations through the public complete plugin inventory" do
    plugin_descriptor = descriptor(capability: "plugin.data@v1", operation: "plugin.data/read@v1")
    provider = stub_const("ExampleToolSet", Class.new)
    allow(McpToolRegistry).to receive(:entries).and_return([])
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:mcp_tool_set).and_return([ provider ])
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:chat_mcp_tool_set).and_return([])
    expect(Syrus::PluginRegistry).to receive(:all_tool_definitions).with(provider).and_return([
      { name: "read_plugin_data", capability_descriptor: plugin_descriptor }
    ])

    registrations = described_class.for_application.registrations

    expect(registrations).to contain_exactly(have_attributes(
      tool_name: "read_plugin_data", surface: :mcp_tool_set,
      source: "ExampleToolSet", descriptor: plugin_descriptor, explicit_descriptor: true
    ))
  end

  it "reports role defaults and effect coverage" do
    coverage = described_class.new([ registration("read_example", descriptor: descriptor) ]).coverage

    expect(coverage).to include(tools: 1, described_tools: 1, explicit_descriptors: 1, legacy_descriptors: 0)
    expect(coverage.dig(:roles, "chat_planner")).to eq(descriptors: 1, defaults: { allow: 1 })
    expect(coverage.dig(:effects, :network_read)).to eq(1)
    expect(coverage.dig(:effects, :destructive)).to eq(0)
  end
end
