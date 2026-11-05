require "rails_helper"

RSpec.describe Permissions::PermissionProfiles do
  def descriptor(operation:, effects:, autonomy: :permanent, default: :ask, roles: [ "chat_planner" ], bundle: nil,
    risk: :low, classifier: nil)
    Permissions::CapabilityDescriptor.new(
      capability: "example.tools@v1", operation:, effects:, risk:,
      requestable_roles: roles, defaults: roles.index_with(default),
      maximum_autonomy: autonomy,
      authority_durations: Permissions::CapabilityDescriptor::AUTHORITY_DURATIONS,
      resource_scope: { type: :none, options: { fields: [] } },
      classifier: classifier || ->(_arguments) { {} }, fingerprint_normalizer: ->(arguments) { arguments },
      redactor: ->(arguments) { arguments }, tool_set_bundle: bundle
    )
  end

  let(:role) { "chat_planner" }
  let(:workspace) { descriptor(operation: "example.tools/read@v1", effects: [ :local_read ]) }
  let(:external) { descriptor(operation: "example.tools/write@v1", effects: [ :external_write ]) }
  let(:protocol) do
    descriptor(operation: "example.tools/submit@v1", effects: [ :internal_write ],
      autonomy: :none, default: :deny)
  end

  it "provides stable versioned canonical profiles and human-sized bundles" do
    expect(described_class.all.map(&:key)).to eq(%w[full_access@v1 ask_on_first_use@v1 restricted@v1])
    expect(Permissions::ToolSetBundles.all.map(&:key)).to eq(
      %w[workspace@v1 knowledge@v1 collaboration@v1 operations@v1 administration@v1]
    )
    expect(workspace.tool_set_bundle).to eq("workspace@v1")
    expect(external.tool_set_bundle).to eq("operations@v1")
    expect(Admin::CapabilitySurfaceRegistry.permission_profiles.pluck(:key)).to eq(
      %w[full_access@v1 ask_on_first_use@v1 restricted@v1]
    )
    expect(Admin::CapabilitySurfaceRegistry.tool_set_bundles.pluck(:key)).to include("administration@v1")
  end

  it "compiles full access into evaluator rules without widening nondelegable capabilities" do
    profile = described_class::FULL_ACCESS
    rules = profile.compile(descriptors: [ workspace, external, protocol ], role:)

    expect(rules).to all(have_attributes(layer: :role, source: "permission_profile:full_access@v1"))
    expect(rules.map(&:policy)).to eq(%i[allow allow deny])

    ceiling = Permissions::PolicyRule.new(id: "provider-deny", layer: :provider, policy: :deny,
      source: "provider", operation: external.operation, delegable: false)
    decision = Permissions::PolicyEvaluator.new(descriptor: external, role:, resource_scope: {},
      rules: rules + [ ceiling ], context: { role: }).call
    expect(decision).to be_deny
    expect(decision.decisive_rule).to eq(ceiling)
  end

  it "keeps ask-on-first-use and restricted quiet for safe isolated work" do
    expect(described_class::ASK_ON_FIRST_USE.policy_for(workspace, role:)).to eq(:allow)
    expect(described_class::ASK_ON_FIRST_USE.policy_for(external, role:)).to eq(:ask)
    expect(described_class::RESTRICTED.policy_for(workspace, role:)).to eq(:allow)
    expect(described_class::RESTRICTED.policy_for(external, role:)).to eq(:deny)
  end

  it "never widens a nondelegable capability in any profile" do
    described_class.all.each do |profile|
      expect(profile.policy_for(protocol, role:)).to eq(:deny), profile.key
    end
  end

  it "does not automatically allow risky local work or isolated execution" do
    risky_read = descriptor(operation: "example.tools/risky_read@v1", effects: [ :local_read ], risk: :medium)
    execution = descriptor(operation: "example.tools/execute@v1", effects: [ :isolated_execution ])

    [ described_class::ASK_ON_FIRST_USE, described_class::RESTRICTED ].each do |profile|
      expect(profile.policy_for(risky_read, role:)).not_to eq(:allow), profile.key
      expect(profile.policy_for(execution, role:)).not_to eq(:allow), profile.key
    end
  end

  it "preserves the coworker downgrade for a dynamically unsafe invocation" do
    coworker_role = AgentRole::COWORKER_CHAT
    operation = "example.tools/dynamic_read@v1"
    dynamic = descriptor(operation:, effects: [ :local_read ], default: :allow, roles: [ coworker_role ],
      classifier: lambda { |arguments|
        arguments[:public] ? { operation:, effects: [ :local_read ], risk: :low, confidence: :certain } :
          { operation:, effects: [ :confidential_read ], risk: :medium, confidence: :certain }
      })
    rules = described_class::FULL_ACCESS.compile(descriptors: [ dynamic ], role: coworker_role)

    safe = Permissions::PolicyEvaluator.new(descriptor: dynamic, role: coworker_role, resource_scope: {},
      rules:, arguments: { public: true }).call
    unsafe = Permissions::PolicyEvaluator.new(descriptor: dynamic, role: coworker_role, resource_scope: {},
      rules:, arguments: { public: false }).call

    expect(safe).to be_allow
    expect(unsafe).to be_ask
    expect(unsafe.chain.last.detail).to eq(:unsafe_classification)
  end

  it "classifies every known effect without a permissive fallback" do
    expected = {
      local_read: "workspace@v1", isolated_workspace_write: "workspace@v1", isolated_execution: "workspace@v1",
      network_read: "knowledge@v1", confidential_read: "knowledge@v1", internal_write: "collaboration@v1",
      communication: "collaboration@v1", credential_use: "operations@v1", external_write: "operations@v1",
      operational: "operations@v1", persistent_autonomy: "operations@v1", financial: "administration@v1",
      privilege_change: "administration@v1", destructive: "administration@v1", irreversible: "administration@v1",
      operator_host_access: "administration@v1"
    }
    expect(expected.keys).to contain_exactly(*Permissions::CapabilityDescriptor::EFFECTS)
    expected.each { |effect, bundle| expect(Permissions::ToolSetBundles.classify([ effect ])).to eq(bundle) }
    expect { Permissions::ToolSetBundles.classify([ :future_effect ]) }.to raise_error(ArgumentError, /unknown effects/)
    expect { Permissions::ToolSetBundles.classify([]) }.to raise_error(ArgumentError, /do not map/)
  end

  it "reports evaluator parity and policy ceilings" do
    profile = described_class::FULL_ACCESS
    ceiling = Permissions::PolicyRule.new(id: "resource-deny", layer: :resource, policy: :deny,
      source: "resource", operation: external.operation, delegable: false)
    findings = Permissions::ProfileParityDiagnostic.new(
      profile:, descriptors: [ workspace, external ], role:, base_rules: [ ceiling ]
    ).call

    expect(findings.map(&:status)).to eq(%i[parity bounded_by_policy])
  end

  it "includes invocation safety downgrades in parity diagnostics" do
    coworker_role = AgentRole::COWORKER_CHAT
    operation = "example.tools/parity_read@v1"
    dynamic = descriptor(operation:, effects: [ :local_read ], default: :allow, roles: [ coworker_role ],
      classifier: ->(_arguments) { { operation:, effects: [ :confidential_read ], risk: :medium, confidence: :certain } })

    finding = Permissions::ProfileParityDiagnostic.new(profile: described_class::FULL_ACCESS,
      descriptors: [ dynamic ], role: coworker_role, arguments: { scope: "private" }).call.sole

    expect(finding).to have_attributes(expected: :allow, actual: :ask, status: :bounded_by_policy)
  end
end
