require "rails_helper"

RSpec.describe Coworkers::EnvironmentPublicationAuthority do
  let(:owner) { Factories.user }
  let(:coworker) { Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "https://example.test/maya.git") }
  let(:environment) { Coworkers::Environment.create!(coworker:, state: "candidate") }
  let(:image) do
    namespace = RuntimeImageNamespace.create!(name: "coworkers/#{coworker.id}", owner_kind: "coworker_environment",
      owner_ref: coworker.id.to_s, provider_key: "synthetic")
    RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{"a" * 64}", platform: "linux/amd64",
      source_kind: "coworker_environment", source_ref: "1", source_digest: "sha256:#{"b" * 64}",
      availability: "available", verification_state: "candidate")
  end
  let(:revision) do
    Coworkers::EnvironmentRevision.create!(environment:, number: 1, state: "candidate",
      source_digest: "sha256:#{"b" * 64}", runtime_image: image)
  end
  let(:risk) do
    snapshot = Coworkers::EnvironmentPublicationRisk::Snapshot.new(
      source_digest: revision.source_digest, base_digest: "sha256:#{"c" * 64}", dependency_digest: "deps",
      sbom_digest: "sbom", vulnerabilities: {}, secret_findings: 0, network_sources: [],
      network_policy_digest: "network", policy_digest: "policy", policy_result: "passed", image_size: 10
    )
    Coworkers::EnvironmentPublicationRisk.call(candidate: snapshot)
  end

  before do
    Feature.create!(slug: "coworker_custom_environments", category: "Labs", name: "x", enabled: true, experimental: true)
    allow(AppSetting).to receive(:beta_mode_enabled?).and_return(true)
  end

  it "returns a pending publication action for the default ask decision" do
    result = described_class.new(owner:, coworker:, environment:, revision:, risk:).call

    expect(result).to be_ask
    expect(result).to be_pending_publication
    expect(result.subject.permission_arguments).to include(
      "revision_id" => revision.id, "image_digest" => image.digest, "risk_deltas" => risk.deltas
    )
  end

  it "honors an exact scoped allow lease and exposes its expiry" do
    descriptor = Coworkers::EnvironmentPermissionProvider.permission_capability_descriptors.find do |entry|
      entry.operation == Coworkers::EnvironmentPermissionProvider.operation(:publish)
    end
    subject = described_class.new(owner:, coworker:, environment:, revision:, risk:).send(:permission_subject)
    expires_at = 20.minutes.from_now
    Syrus::Host::PermissionManagement.new(owner).lease!({
      "capability" => descriptor.capability, "operation" => descriptor.operation,
      "role" => AgentRole::COWORKER, "subject_selector_type" => "agent", "subject_selector_id" => coworker.id.to_s,
      "resource_scope" => {}, "arguments" => subject.permission_arguments,
      "duration" => "invocation", "expires_at" => expires_at.iso8601, "max_uses" => 1
    }, actor: owner)

    result = described_class.new(owner:, coworker:, environment:, revision:, risk:).call

    expect(result).to be_allow
    expect(result.action).to eq(:publish)
    expect(result.expires_at).to be_within(1.second).of(expires_at)
  end

  it "denies publication when the feature gate is disabled even if a build succeeded" do
    Feature.find_by!(slug: "coworker_custom_environments").update!(enabled: false)

    result = described_class.new(owner:, coworker:, environment:, revision:, risk:).call

    expect(result).to be_deny
    expect(result.action).to eq(:retain_candidate)
  end

  it "does not infer publication authority from a successful build request" do
    expect(described_class.new(owner:, coworker:, environment:, revision:, risk:).call).to be_ask
  end
end
