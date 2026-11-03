require "rails_helper"

# End-to-end invariants for the unified permission model: every consequential
# agent effect, whether it enters through MCP tool dispatch or not (scheduled
# delivery, ingestion, host/container/provider-native execution), must have
# exactly one stable capability mapping, a policy explanation, an append-only
# audit trail, and revocation that takes effect immediately.
#
# The effect list is derived from each contract module's own registry, so a new
# operation added to one of them is covered here without editing this file.
module UnifiedEffectCoverage
  Effect = Struct.new(:label, :source, :descriptor, :tool_name, keyword_init: true)

  MCP_BACKED = [
    Permissions::EffectActions, Permissions::IngestionActions,
    Permissions::OperationalActions, Permissions::JobLifecycle
  ].freeze

  def self.effects
    mcp = MCP_BACKED.flat_map do |source|
      source.tool_names.map do |name|
        Effect.new(label: "#{source.name.demodulize}##{name}", source:, tool_name: name, descriptor: source.descriptor_for(name))
      end
    end
    non_mcp = Permissions::ExecutionActions::LOCATIONS.map do |location|
      Effect.new(label: "ExecutionActions##{location}", source: Permissions::ExecutionActions, tool_name: nil,
        descriptor: Permissions::ExecutionActions.descriptor_for(location))
    end
    mcp + non_mcp
  end
end

RSpec.describe "Unified consequential-effect coverage" do

  def self.effects = UnifiedEffectCoverage.effects

  let(:user) { Factories.user }
  let(:management) { Permissions::Management.new(user) }

  def rule_payload(descriptor)
    { "capability" => descriptor.capability, "operation" => descriptor.operation, "role" => "any",
      "subject_selector_type" => "workflow_role", "subject_selector_id" => descriptor.requestable_roles.first }
  end

  def explain(descriptor)
    role = descriptor.requestable_roles.first
    management.explain(descriptor:, role:, resource_scope: {}, arguments: {},
      context: { user:, subject_selector_type: "workflow_role", subject_selector_id: role })
  end

  it "covers a meaningful set of effects, including ones outside MCP dispatch" do
    labels = self.class.effects.map(&:label)
    expect(labels).to include("ExecutionActions#host", "ExecutionActions#container", "ExecutionActions#provider_native")
    expect(labels).to include("EffectActions#schedule_wakeup", "IngestionActions#ingest_pull_request")
    expect(labels.uniq).to eq(labels)
  end

  it "gives every effect exactly one versioned capability and operation shared across the catalog" do
    contracts = self.class.effects.map { |effect| [ effect.descriptor.capability, effect.descriptor.operation ] }
    expect(contracts.uniq.length).to eq(contracts.length), "two effects share one capability operation"

    self.class.effects.each do |effect|
      descriptor = effect.descriptor
      expect(descriptor.capability).to match(/\Asyrus\.[a-z_]+@v\d+\z/), effect.label
      expect(descriptor.operation).to match(%r{\Asyrus\.[a-z_]+/[a-z_]+@v\d+\z}), effect.label
      # find! raises unless the catalog resolves the pair to exactly one descriptor.
      expect(Permissions::Catalog.find!(capability: descriptor.capability, operation: descriptor.operation))
        .to have_attributes(capability: descriptor.capability, operation: descriptor.operation), effect.label
    end
  end

  it "registers every MCP-backed effect on its tool surface with the identical contract" do
    entries = McpToolRegistry.entries.group_by(&:tool_name)
    self.class.effects.select(&:tool_name).each do |effect|
      registered = Array(entries[effect.tool_name]).select(&:explicit_descriptor)
      expect(registered).not_to be_empty, "#{effect.label} has no explicit MCP registration"
      expect(registered.map { |entry| entry.descriptor.operation }.uniq).to eq([ effect.descriptor.operation ]), effect.label
    end
  end

  it "classifies every effect with certain, declared effects and a redacted, stable fingerprint" do
    self.class.effects.each do |effect|
      descriptor = effect.descriptor
      classification = descriptor.classify({})
      expect(classification[:operation]).to eq(descriptor.operation), effect.label
      expect(classification[:effects]).not_to be_empty, effect.label
      expect(classification[:effects] - Permissions::CapabilityDescriptor::EFFECTS).to be_empty, effect.label
      expect(Permissions::InvocationFingerprint.call(descriptor:, arguments: {}))
        .to eq(Permissions::InvocationFingerprint.call(descriptor:, arguments: {})), effect.label
    end
  end

  it "explains the policy for every effect and attributes a deny to its rule, then restores the default on revocation" do
    self.class.effects.each do |effect|
      descriptor = effect.descriptor
      baseline = explain(descriptor)
      expect(baseline.invocation).to have_attributes(capability: descriptor.capability, operation: descriptor.operation), effect.label
      expect(baseline.chain).not_to be_empty, effect.label
      expect(baseline.to_h).to include(:policy, :decisive_rule, :chain, :invocation), effect.label

      rule = management.deny!(rule_payload(descriptor), actor: user)
      denied = explain(descriptor)
      expect(denied).to be_deny, effect.label
      expect(denied.decisive_rule.id).to eq(rule.to_policy_rule.id), effect.label

      management.revoke_rule!(rule.id, actor: user)
      expect(explain(descriptor).policy).to eq(baseline.policy), effect.label
    end
  end

  it "writes an append-only audit trail for every rule created and revoked for an effect" do
    self.class.effects.each do |effect|
      rule = management.deny!(rule_payload(effect.descriptor), actor: user)
      management.revoke_rule!(rule.id, actor: user)

      events = rule.audit_events.reload
      expect(events.map(&:event_type)).to eq(%w[created revoked]), effect.label
      expect(events.map(&:actor_user).uniq).to eq([ user ]), effect.label
      expect(events.first.snapshot).to include("capability" => effect.descriptor.capability, "operation" => effect.descriptor.operation)
      expect { events.first.update!(event_type: "updated") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end
  end

  it "stops execution before it starts once denied and resumes after the rule is revoked" do
    request = Execution::Request.new(**Execution::Request.members.index_with { nil }, command: %w[ls], network: "agent", env: {},
      chat_session: ChatSession.create!(user:, mode: "coding"))
    descriptor = Permissions::ExecutionActions.descriptor_for(:host)

    rule = management.deny!(rule_payload(descriptor).merge("subject_selector_type" => "coding_chat", "subject_selector_id" => nil).compact, actor: user)
    expect(Permissions::ExecutionGate.new.call(request, location: :host)).to be_denied

    management.revoke_rule!(rule.id, actor: user)
    expect(Permissions::ExecutionGate.new.call(request, location: :host)).not_to be_denied
  end
end
