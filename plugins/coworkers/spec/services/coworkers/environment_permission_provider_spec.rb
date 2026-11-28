require "rails_helper"

RSpec.describe Coworkers::EnvironmentPermissionProvider do
  let(:subject) do
    Coworkers::EnvironmentPermissionSubject.new(
      coworker_id: 7, owner_user_id: 3, environment_id: 11, revision_id: 19,
      source_digest: "sha256:source", base_digest: "sha256:base", image_digest: "sha256:image",
      policy_result: "passed", risk_deltas: { packages_added: 2 },
      affected_execution_ids: [ 9, 4, 9 ], reason: "security response"
    )
  end

  before do
    Feature.create!(slug: "coworker_custom_environments", category: "Labs", name: "x", enabled: true, experimental: true)
    allow(AppSetting).to receive(:beta_mode_enabled?).and_return(true)
  end

  it "registers a versioned descriptor for every lifecycle operation" do
    descriptors = described_class.permission_capability_descriptors.index_by(&:operation)

    expect(descriptors.keys).to contain_exactly(*described_class::OPERATIONS.values)
    expect(descriptors.values).to all(have_attributes(capability: described_class::CAPABILITY,
                                                       maximum_autonomy: :invocation))
    expect(descriptors.values.flat_map { |descriptor| descriptor.defaults.values }.uniq).to eq([ :ask ])
  end

  it "binds authorization to exact lifecycle evidence and affected executions" do
    normalized = described_class.normalize(subject)

    expect(normalized).to include(
      "coworker_id" => 7, "owner_user_id" => 3, "environment_id" => 11, "revision_id" => 19,
      "source_digest" => "sha256:source", "base_digest" => "sha256:base", "image_digest" => "sha256:image",
      "policy_result" => "passed", "risk_deltas" => { "packages_added" => 2 },
      "affected_execution_ids" => [ 4, 9 ]
    )
    expect(described_class.redact(subject)).to include("reason" => "[REDACTED REASON]")
  end

  it "makes the disabled feature gate an authority ceiling for ordinary operations" do
    Feature.find_by!(slug: "coworker_custom_environments").update!(enabled: false)

    described_class::NORMAL_OPERATIONS.each do |operation|
      expect(described_class.feature_gate_allows?(operation, subject:)).to be(false)
    end
  end

  it "keeps only explicitly scoped administrator repair available while disabled" do
    Feature.find_by!(slug: "coworker_custom_environments").update!(enabled: false)
    repair = Coworkers::EnvironmentPermissionSubject.new(**subject.to_h.merge(administrator_repair: true))

    described_class::REPAIR_OPERATIONS.each do |operation|
      expect(described_class.feature_gate_allows?(operation, subject:)).to be(false)
      expect(described_class.feature_gate_allows?(operation, subject: repair)).to be(true)
    end
  end
end
