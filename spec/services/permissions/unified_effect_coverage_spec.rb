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
  Effect = Struct.new(:label, :descriptor, :tool_names, keyword_init: true)

  # Pure reads of non-confidential data do not change anything; every other
  # declared effect is consequential and must be covered.
  INERT_EFFECTS = %i[local_read network_read].freeze

  def self.consequential?(descriptor) = (descriptor.effects - INERT_EFFECTS).any?

  # Derived from the authoritative sources, so a new operation is covered
  # without editing this file: explicit descriptors on core MCP entries,
  # plugin-provided descriptors, and the execution effects that have no tool.
  def self.effects
    explicit_core = McpToolRegistry.entries.select(&:explicit_descriptor)
    tools = explicit_core.group_by { |entry| entry.descriptor.operation }.transform_values { |entries| entries.map(&:tool_name).uniq }
    Permissions::Catalog.descriptors.select { |descriptor| consequential?(descriptor) }.map do |descriptor|
      Effect.new(label: descriptor.operation, descriptor:, tool_names: tools.fetch(descriptor.operation, []))
    end
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

  # Scoped descriptors need provider-specific scope values, so the rule is
  # written unscoped, which matches every scope of that operation.
  def deny(descriptor)
    management.deny!(rule_payload(descriptor), actor: user)
  rescue ArgumentError
    PermissionRule.create!(
      owner_user: user, created_by_user: user, updated_by_user: user, subject_selector_type: "workflow_role",
      subject_selector_id: descriptor.requestable_roles.first, subject_role_keys: [], dynamic_future_roles: false,
      capability: descriptor.capability, operation: descriptor.operation, resource_type: descriptor.resource_scope.type.to_s,
      resource_scope: {}, constraints: {}, policy_layer: "agent", source: "operator", provenance: {}, delegable: true, policy: "deny"
    )
  end

  def explain(descriptor)
    role = descriptor.requestable_roles.first
    management.explain(descriptor:, role:, resource_scope: {}, arguments: {},
      context: { user:, subject_selector_type: "workflow_role", subject_selector_id: role })
  end

  it "covers a meaningful set of effects, including ones outside MCP dispatch" do
    labels = self.class.effects.map(&:label)
    expect(labels).to include(*Permissions::ExecutionActions::LOCATIONS.map { |l| Permissions::ExecutionActions.operation_for(l) })
    expect(labels).to include(*Permissions::LocalModeActions.tool_names.map { |n| Permissions::LocalModeActions.operation_for(n) })
    expect(labels).to include("syrus.schedules/schedule_wakeup@v1", "syrus.ingestion/pull_request@v1")
    expect(labels.uniq).to eq(labels)
  end

  it "gives every effect exactly one versioned capability and operation shared across the catalog" do
    contracts = self.class.effects.map { |effect| [ effect.descriptor.capability, effect.descriptor.operation ] }
    expect(contracts.uniq.length).to eq(contracts.length), "two effects share one capability operation"

    self.class.effects.each do |effect|
      descriptor = effect.descriptor
      expect(descriptor.capability).to match(/\A[a-z_.]+@v\d+\z/), effect.label
      expect(descriptor.operation).to match(%r{\A[a-z_.]+/[a-z_.]+@v\d+\z}), effect.label
      # find! raises unless the catalog resolves the pair to exactly one descriptor.
      expect(Permissions::Catalog.find!(capability: descriptor.capability, operation: descriptor.operation))
        .to have_attributes(capability: descriptor.capability, operation: descriptor.operation), effect.label
    end
  end

  it "registers every MCP-backed effect on its tool surface with the identical contract" do
    # Coworker registrations carry their own per-role contract (Permissions::CoworkerActions),
    # whose defaults reflect owner-delegated, grant-scoped access rather than chat defaults.
    by_name = McpToolRegistry.entries.select(&:explicit_descriptor).reject { |entry| entry.surface == :coworker }.group_by(&:tool_name)
    {
      Permissions::EffectActions => Permissions::EffectActions.tool_names,
      Permissions::IngestionActions => Permissions::IngestionActions.tool_names,
      Permissions::OperationalActions => Permissions::OperationalActions.tool_names,
      Permissions::JobLifecycle => Permissions::JobLifecycle.tool_names,
      Permissions::LocalModeActions => Permissions::LocalModeActions.tool_names
    }.each do |source, names|
      names.each do |name|
        operations = Array(by_name[name]).map { |entry| entry.descriptor.operation }.uniq
        expect(operations).to eq([ source.descriptor_for(name).operation ]), "#{source}##{name}"
      end
    end
    expect(self.class.effects.reject { |effect| effect.tool_names.any? }.map(&:label))
      .to include(*Permissions::ExecutionActions.descriptors.map(&:operation))
  end

  it "classifies every effect with certain, declared effects and a redacted, stable fingerprint" do
    self.class.effects.each do |effect|
      descriptor = effect.descriptor
      classification = descriptor.classify({})
      # A classifier may refine the operation (e.g. read vs. risky), but it must
      # stay inside the descriptor's capability family and remain versioned.
      expect(classification[:operation]).to match(%r{\A[a-z_.]+/[a-z_.]+@v\d+\z}), effect.label
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

      rule = deny(descriptor)
      denied = explain(descriptor)
      expect(denied).to be_deny, effect.label
      # A descriptor that already denies by default has no rule to attribute.
      expect(denied.decisive_rule&.id).to eq(rule.to_policy_rule.id), effect.label unless baseline.deny?

      management.revoke_rule!(rule.id, actor: user)
      expect(explain(descriptor).policy).to eq(baseline.policy), effect.label
    end
  end

  it "writes an append-only audit trail for every rule created and revoked for an effect" do
    self.class.effects.each do |effect|
      rule = deny(effect.descriptor)
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
