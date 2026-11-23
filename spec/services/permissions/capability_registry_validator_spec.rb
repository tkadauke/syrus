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
      deniable_reason: :external_ingestion,
      classifier: ->(arguments) { arguments },
      fingerprint_normalizer: ->(arguments) { arguments },
      redactor: ->(arguments) { arguments }
    }.merge(overrides))
  end

  def registration(name, descriptor:, surface: :chat, source: "ExamplePlugin", explicit_descriptor: descriptor.present?, ungated: false)
    described_class::Registration.new(
      tool_name: name, surface: surface, source: source, descriptor: descriptor,
      explicit_descriptor: explicit_descriptor, ungated:
    )
  end

  it "rejects missing descriptors with an actionable provider and tool diagnostic" do
    validator = described_class.new([ registration("read_example", descriptor: nil) ])

    expect { validator.validate! }.to raise_error(described_class::ValidationError, /ExamplePlugin chat tool "read_example" has no explicit capability_descriptor/)
  end

  # Regression: `ungated` used to be a registry flag no gate shared with the
  # descriptor, so a tool could bypass one gate and be denied by another.
  it "rejects an ungated tool whose descriptor is not essential" do
    validator = described_class.new([ registration("harmless_protocol_tool", descriptor: nil, ungated: true) ])

    expect(validator.findings.map(&:code)).to include(:ungated_not_essential)
  end

  it "accepts an ungated tool whose descriptor is essential" do
    essential = descriptor(effects: [ :local_read ], deniable_reason: nil, essential: true)

    expect(described_class.new([ registration("harmless_protocol_tool", descriptor: essential, ungated: true) ]).validate!).to be(true)
  end

  it "rejects an operation that is neither essential, gated by a barrier effect, nor deniable for a reason" do
    unclassified = descriptor(effects: [ :internal_write ], deniable_reason: nil)

    finding = described_class.new([ registration("write_example", descriptor: unclassified) ]).findings.sole
    expect(finding.code).to eq(:unclassified_consequence)
    expect(finding.message).to include("write_example", "no barrier effect")
  end

  it "accepts an operation whose barrier effect classifies it" do
    gated = descriptor(effects: [ :internal_write, :communication ], deniable_reason: nil)

    expect(described_class.new([ registration("send_example", descriptor: gated) ]).findings).to be_empty
  end

  it "rejects synthesized descriptors" do
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

  it "does not report contract conflicts between synthesized descriptors" do
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

  it "accepts the coworker surface's role projection of a chat descriptor" do
    chat = registration("read_example", descriptor: descriptor)
    workflow = registration("read_example", surface: :workflow, descriptor: chat.descriptor)
    coworker_descriptor = Permissions::CapabilityDescriptorAdapter.for_coworker_parity(chat.descriptor)
    coworker = registration("read_example", surface: :coworker, descriptor: coworker_descriptor)

    expect(described_class.new([ chat, coworker, workflow ]).findings).to be_empty
  end

  it "rejects a coworker projection that changes the authorization contract" do
    chat = registration("read_example", descriptor: descriptor)
    coworker = registration("read_example", surface: :coworker, descriptor: descriptor(
      effects: [ :confidential_read ],
      requestable_roles: [ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ],
      defaults: { AgentRole::COWORKER_CHAT => :ask, AgentRole::COWORKER => :ask }
    ))

    expect(described_class.new([ chat, coworker ]).findings.map(&:code)).to include(:conflicting_descriptor)
  end

  it "builds application registrations through the public complete plugin inventory" do
    plugin_descriptor = descriptor(capability: "plugin.data@v1", operation: "plugin.data/read@v1")
    provider = stub_const("ExampleToolSet", Class.new)
    allow(McpToolRegistry).to receive(:entries).and_return([])
    allow(Syrus::Plugin::Toolkit).to receive(:workflow_tool_sets).and_return([ provider ])
    allow(Syrus::Plugin::Toolkit).to receive(:chat_tool_sets).and_return([])
    allow(Syrus::Plugin::Toolkit).to receive(:permission_providers).and_return([])
    allow(Syrus::PluginRegistry).to receive(:all_plugins).and_return([])
    expect(Syrus::PluginRegistry).to receive(:all_tool_definitions).with(provider).and_return([
      { name: "read_plugin_data", capability_descriptor: plugin_descriptor }
    ])

    registrations = described_class.for_application.registrations

    expect(registrations).to contain_exactly(have_attributes(
      tool_name: "read_plugin_data", surface: :mcp_tool_set,
      source: "ExampleToolSet", descriptor: plugin_descriptor, explicit_descriptor: true
    ))
  end

  it "rejects a plugin definition without an explicit descriptor" do
    provider = stub_const("UnratchetedToolSet", Class.new)
    allow(McpToolRegistry).to receive(:entries).and_return([])
    allow(Syrus::Plugin::Toolkit).to receive(:workflow_tool_sets).and_return([ provider ])
    allow(Syrus::Plugin::Toolkit).to receive(:chat_tool_sets).and_return([])
    allow(Syrus::Plugin::Toolkit).to receive(:permission_providers).and_return([])
    allow(Syrus::PluginRegistry).to receive(:all_tool_definitions).with(provider).and_return([{ name: "read_plugin_data" }])

    finding = described_class.for_application.findings.find { |candidate| candidate.code == :missing_descriptor }

    expect(finding.message).to include('UnratchetedToolSet mcp_tool_set tool "read_plugin_data"')
  end

  it "rejects a malformed explicit plugin descriptor" do
    provider = stub_const("MalformedToolSet", Class.new)
    allow(McpToolRegistry).to receive(:entries).and_return([])
    allow(Syrus::Plugin::Toolkit).to receive(:workflow_tool_sets).and_return([ provider ])
    allow(Syrus::Plugin::Toolkit).to receive(:chat_tool_sets).and_return([])
    allow(Syrus::Plugin::Toolkit).to receive(:permission_providers).and_return([])
    allow(Syrus::PluginRegistry).to receive(:all_tool_definitions).with(provider).and_return([
      { name: "read_plugin_data", capability_descriptor: { capability: "unversioned" } }
    ])

    expect { described_class.for_application }.to raise_error(ArgumentError)
  end

  it "keeps concrete plugin inventories out of the core validator" do
    source = Rails.root.join("app/services/permissions/capability_registry_validator.rb").read

    expect(source).not_to include("LEGACY_PROVIDER_DIGESTS", "ChatToolSet", "WorkflowToolSet")
  end

  it "reports role defaults and effect coverage" do
    coverage = described_class.new([ registration("read_example", descriptor: descriptor) ]).coverage

    expect(coverage).to include(tools: 1, described_tools: 1, explicit_descriptors: 1,
      ungated_tools: 0, tool_set_bundles: { "knowledge@v1" => 1 })
    expect(coverage.dig(:roles, "chat_planner")).to eq(descriptors: 1, defaults: { allow: 1 })
    expect(coverage.dig(:effects, :network_read)).to eq(1)
    expect(coverage.dig(:effects, :destructive)).to eq(0)
  end

  it "keeps all bundled executable registrations explicit" do
    registrations = described_class.for_application.registrations.reject(&:ungated)

    expect(registrations).not_to be_empty
    expect(registrations).to all(have_attributes(explicit_descriptor: true))
  end

  it "keeps compatibility registry APIs removed" do
    expect(described_class::Registration.members).not_to include(:compatibility_descriptor)
    expect(McpToolRegistry::Entry.members).not_to include(:compatibility_descriptor)
    %i[legacy_chat legacy_workflow legacy_coworker legacy_entry].each do |method_name|
      expect(McpToolRegistry.respond_to?(method_name, true)).to be(false)
    end

    definition = Syrus::PluginApi::Definition.new(name: "example", namespace: Module.new, lib_dir: __dir__)
    expect(definition).not_to respond_to(:capability_descriptor_compatibility)
  end
end
