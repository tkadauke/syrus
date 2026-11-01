require "rails_helper"

RSpec.describe Coworkers::PermissionCutoverReport do
  let(:owner) { Factories.user }
  let(:coworker) do
    Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-cutover",
      workspace_repo: "https://github.com/acme/workspace.git"
    )
  end

  def descriptor(default: :ask, roles: [ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ])
    Permissions::CapabilityDescriptor.new(
      capability: "syrus.read_jobs@v1", operation: "syrus.read_jobs/list@v1",
      effects: [ :network_read ], risk: :low, requestable_roles: roles,
      defaults: roles.index_with { default }, maximum_autonomy: :permanent,
      authority_durations: %i[invocation permanent], resource_scope: { type: :none },
      classifier: ->(arguments) { arguments }, fingerprint_normalizer: ->(arguments) { arguments },
      redactor: ->(arguments) { arguments }
    )
  end

  def registration(permission_descriptor, explicit: true)
    Permissions::CapabilityRegistryValidator::Registration.new(
      tool_name: "list_jobs", surface: :coworker, source: "core",
      descriptor: permission_descriptor, explicit_descriptor: explicit
    )
  end

  it "reports the before and after policy without creating active permission rules" do
    coworker.grants.create!(capability: "syrus.read_jobs", approval_policy: "auto")
    report = described_class.new(coworker: coworker, registrations: [ registration(descriptor) ], findings: []).as_json

    expect(report).to include(ready: true, descriptor_gaps: [], migration_errors: [])
    expect(report[:legacy_grants]).to contain_exactly(include(capability: "syrus.read_jobs", effective_policy: :allow))
    expect(report[:recommended_defaults]).to contain_exactly(include(
      capability: "syrus.read_jobs@v1", operation: "syrus.read_jobs/list@v1",
      roles: { AgentRole::COWORKER_CHAT => "ask", AgentRole::COWORKER => "ask" }
    ))
    expect(report[:lost_authority].map { |item| item[:role] }).to contain_exactly(AgentRole::COWORKER_CHAT, AgentRole::COWORKER)
    expect(report[:requestable_replacements]).to contain_exactly(include(operation: "syrus.read_jobs/list@v1"))
    expect(PermissionRule.where(owner_user: owner)).to be_empty
  end

  it "blocks cutover when a legacy grant lacks an explicit complete coworker descriptor" do
    coworker.grants.create!(capability: "syrus.read_jobs", approval_policy: "confirm")
    report = described_class.new(
      coworker: coworker,
      registrations: [ registration(descriptor(roles: [ AgentRole::COWORKER_CHAT ]), explicit: false) ],
      findings: []
    ).as_json

    expect(report[:ready]).to be(false)
    expect(report[:descriptor_gaps]).to contain_exactly(include(
      legacy_capability: "syrus.read_jobs",
      reasons: contain_exactly("missing explicit descriptors", "missing coworker role defaults")
    ))
  end

  it "surfaces registry findings affecting a legacy grant as blocking migration errors" do
    coworker.grants.create!(capability: "syrus.read_jobs", approval_policy: "confirm")
    candidate = registration(descriptor)
    finding = Permissions::CapabilityRegistryValidator::Finding.new(
      code: :conflicting_descriptor, message: "descriptor conflict", registrations: [ candidate ]
    )

    report = described_class.new(coworker: coworker, registrations: [ candidate ], findings: [ finding ]).as_json

    expect(report[:ready]).to be(false)
    expect(report[:migration_errors]).to contain_exactly(
      code: "conflicting_descriptor", message: "descriptor conflict", tools: [ "list_jobs" ]
    )
  end
end
