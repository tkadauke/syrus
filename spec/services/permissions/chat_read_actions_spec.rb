require "rails_helper"

RSpec.describe Permissions::ChatReadActions do
  let(:entries) do
    McpToolRegistry.entries(surface: :chat).select do |entry|
      described_class.tool_names.include?(entry.tool_name)
    end.index_by(&:tool_name)
  end

  it "explicitly describes the complete chat read and diagnostic inventory" do
    expect(entries.keys).to contain_exactly(*described_class.tool_names)
    expect(entries.values).to all(
      have_attributes(mutation: false, explicit_descriptor: true)
    )
  end

  it "groups reads into the supported domain capability families" do
    expect(entries.values.map { |entry| entry.descriptor.capability }.uniq).to contain_exactly(
      described_class::JOBS,
      described_class::EPICS,
      described_class::CHATS,
      described_class::WORKFLOWS,
      described_class::QUEUES,
      described_class::DOCUMENTS,
      described_class::REPOSITORIES,
      described_class::RUNTIME,
      described_class::LOCAL,
      described_class::ADMIN
    )
  end

  it "keeps every read default-allowed with durable read authority" do
    entries.each_value do |entry|
      descriptor = entry.descriptor

      expect(descriptor.effects).to eq([ :local_read ])
      expect(descriptor.risk).to eq(:low)
      expect(descriptor.defaults.values.uniq).to eq([ :allow ])
      expect(descriptor.maximum_autonomy).to eq(:permanent)
      expect(descriptor.authority_durations).to eq(Permissions::CapabilityDescriptor::AUTHORITY_DURATIONS)
      expect(descriptor.classify({})).to include(confidence: :certain)
    end
  end

  it "preserves discovery tiers and access restrictions" do
    expect(entries.fetch("list_jobs")).to have_attributes(tier: :essential, required_roles: [])
    expect(entries.fetch("read_workflow")).to have_attributes(tier: :deferred, required_roles: [])
    expect(entries.fetch("runtime_status")).to have_attributes(
      tier: :essential, feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING, AgentRole::CHAT_PLANNER, AgentRole::COWORKER_CHAT ]
    )
    expect(entries.fetch("read_file")).to have_attributes(
      tier: :essential, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ]
    )
    expect(entries.fetch("admin_overview")).to have_attributes(tier: :essential, admin_only: true)
    expect(entries.fetch("read_queue")).to have_attributes(tier: :deferred, admin_only: true)
  end

  it "removes the migrated reads from compatibility coverage" do
    registrations = Permissions::CapabilityRegistryValidator.for_application.registrations.select do |registration|
      registration.source == "core" && registration.surface == :chat &&
        described_class.tool_names.include?(registration.tool_name)
    end

    validator = Permissions::CapabilityRegistryValidator.new(registrations)

    expect(validator.findings).to be_empty
    expect(validator.coverage).to include(
      tools: described_class.tool_names.length,
      explicit_descriptors: described_class.tool_names.length
    )
  end

  it "drives authorization from each explicit descriptor" do
    entries.each_value do |entry|
      role = entry.descriptor.requestable_roles.first
      decision = Permissions::PolicyEvaluator.new(
        descriptor: entry.descriptor, role:, resource_scope: {}, rules: [], context: {}, arguments: {}
      ).call

      expect(decision.policy).to eq(:allow)
    end
  end
end
