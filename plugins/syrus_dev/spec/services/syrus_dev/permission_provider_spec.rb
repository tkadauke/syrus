require "rails_helper"

RSpec.describe SyrusDev::PermissionProvider do
  it "declares the complete Syrus Dev tool inventory with role-specific defaults" do
    descriptors = described_class.permission_capability_descriptors.index_by(&:operation)

    expect(descriptors.keys).to contain_exactly(
      "syrus_dev.performance/read@v1",
      "syrus_dev.logs/search@v1",
      "syrus_dev.workspace_reuse/read@v1"
    )
    expect(descriptors.values).to all(have_attributes(
      capability: "syrus_dev.read_diagnostics@v1",
      effects: [ :confidential_read ],
      risk: :medium
    ))
    expect(descriptors.fetch("syrus_dev.logs/search@v1").defaults).to include(
      AgentRole::WORKFLOW_IMPLEMENT => :allow,
      AgentRole::AGENT_INSIGHT => :allow,
      AgentRole::COWORKER_CHAT => :ask,
      AgentRole::COWORKER => :ask
    )
    expect(descriptors.fetch("syrus_dev.workspace_reuse/read@v1").requestable_roles)
      .to contain_exactly(AgentRole::WORKFLOW_IMPLEMENT)
  end

  it "redacts log queries from authorization evidence" do
    descriptor = described_class.capability_descriptor("syrus_dev.logs/search@v1")

    expect(descriptor.classify(query: "password leaked")).to include(
      operation: "syrus_dev.logs/search@v1",
      effects: [ :confidential_read ],
      confidence: :certain
    )
    expect(descriptor.redact(query: "password leaked", level: "error"))
      .to eq("query" => "[REDACTED LOG QUERY]", "level" => "error")
  end

  it "authorizes workflow diagnostics by default but asks for coworker access" do
    descriptor = described_class.capability_descriptor("syrus_dev.logs/search@v1")

    workflow = Permissions::PolicyEvaluator.new(
      descriptor:, role: AgentRole::WORKFLOW_IMPLEMENT, resource_scope: {},
      rules: [], context: {}, arguments: { query: "timeout" }
    ).call
    coworker = Permissions::PolicyEvaluator.new(
      descriptor:, role: AgentRole::COWORKER, resource_scope: {},
      rules: [], context: {}, arguments: { query: "timeout" }
    ).call

    expect(workflow).to be_allow
    expect(coworker).to be_ask
  end
end
