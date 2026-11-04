require "rails_helper"

RSpec.describe Permissions::PermissionProfiles do
  def descriptor(operation:, effects:, autonomy: :permanent, default: :ask, roles: [ "chat_planner" ], bundle: nil)
    Permissions::CapabilityDescriptor.new(
      capability: "example.tools@v1", operation:, effects:, risk: :low,
      requestable_roles: roles, defaults: roles.index_with(default),
      maximum_autonomy: autonomy,
      authority_durations: Permissions::CapabilityDescriptor::AUTHORITY_DURATIONS,
      resource_scope: { type: :none, options: { fields: [] } },
      classifier: ->(_arguments) { {} }, fingerprint_normalizer: ->(arguments) { arguments },
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

  it "reports evaluator parity and policy ceilings" do
    profile = described_class::FULL_ACCESS
    ceiling = Permissions::PolicyRule.new(id: "resource-deny", layer: :resource, policy: :deny,
      source: "resource", operation: external.operation, delegable: false)
    findings = Permissions::ProfileParityDiagnostic.new(
      profile:, descriptors: [ workspace, external ], role:, base_rules: [ ceiling ]
    ).call

    expect(findings.map(&:status)).to eq(%i[parity bounded_by_policy])
  end
end
