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
      source_digest: "sha256:#{"b" * 64}", runtime_image: image, build_request: build_request)
  end
  let(:build_request) do
    RuntimeImageBuildRequest.create!(runtime_image_namespace: image.runtime_image_namespace, state: "succeeded",
      platform: "linux/amd64", dedup_key: "publication-authority", source_kind: "coworker_environment",
      source_ref: "1", source_digest: revision_source_digest, recipe_digest: "sha256:#{"d" * 64}",
      requester_kind: "coworker", requester_ref: coworker.id.to_s, recipe: {})
  end
  let(:revision_source_digest) { "sha256:#{"b" * 64}" }
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

  def attest(runtime_image, policy: nil)
    policy ||= RuntimeImages::Builds::Runner.new.verification_policy(
      build_request, base_policy: RuntimeImages::Verifications::Policy.current
    )
    attempt = runtime_image.runtime_image_verification_attempts.create!(
      number: runtime_image.runtime_image_verification_attempts.maximum(:number).to_i + 1,
      image_digest: runtime_image.digest, state: "accepted", decision: "candidate",
      policy_snapshot: policy, policy_digest: RuntimeImages::Verifications::CanonicalJson.digest(policy),
      started_at: Time.current, finished_at: Time.current
    )
    attempt.create_attestation!(runtime_image:, image_digest: runtime_image.digest,
      policy_digest: attempt.policy_digest, evidence_digest: runtime_image.digest, outcome: "accepted",
      issued_at: Time.current, expires_at: 1.day.from_now)
  end

  def prior_activation(source_digest: revision.source_digest)
    prior = Coworkers::EnvironmentRevision.create!(environment:, number: 2, state: "retired",
      source_digest:, runtime_image: image, build_request: build_request)
    environment.activations.create!(revision: prior, runtime_image: image,
      verification_attestation: attest(image), source_digest:, image_digest: image.digest,
      authority_kind: "permission", actor: "operator", activated_at: 1.hour.ago)
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

  it "inherits prior authority for unchanged source after the complete current policy passes" do
    activation = prior_activation

    result = described_class.new(owner:, coworker:, environment:, revision:, risk:).call

    expect(result).to be_allow
    expect(result.inherited_from).to eq(activation)
  end

  it "requires fresh authority when source changed" do
    prior_activation(source_digest: "sha256:#{"9" * 64}")

    expect(described_class.new(owner:, coworker:, environment:, revision:, risk:).call).to be_ask
  end

  it "requires fresh authority until the newest attempt passes the current policy" do
    prior_activation
    stale_policy = RuntimeImages::Verifications::Policy.current.deep_merge("image" => { "max_layers" => 1 })
    attest(image, policy: stale_policy)

    result = described_class.new(owner:, coworker:, environment:, revision:, risk:).call

    expect(result).to be_ask
    expect(result.inherited_from).to be_nil
  end

  it "revalidates the live feature gate immediately before publication" do
    attest(image)
    result = described_class.new(owner:, coworker:, environment:, revision:, risk:).call
    Feature.find_by!(slug: "coworker_custom_environments").update!(enabled: false)

    expect {
      described_class.revalidate!(result, owner:, coworker:, environment:, revision:)
    }.to raise_error(Coworkers::EnvironmentRevision::InvalidTransition, /no longer authorized/)
  end

  it "revalidates a revoked one-use lease immediately before publication" do
    descriptor = described_class.new(owner:, coworker:, environment:, revision:, risk:).send(:descriptor)
    subject = described_class.new(owner:, coworker:, environment:, revision:, risk:).send(:permission_subject)
    lease = Syrus::Host::PermissionManagement.new(owner).lease!({
      "capability" => descriptor.capability, "operation" => descriptor.operation,
      "role" => AgentRole::COWORKER, "subject_selector_type" => "agent", "subject_selector_id" => coworker.id.to_s,
      "resource_scope" => {}, "arguments" => subject.permission_arguments,
      "duration" => "invocation", "max_uses" => 1
    }, actor: owner)
    result = described_class.new(owner:, coworker:, environment:, revision:, risk:).call
    lease.revoke!(actor: owner)

    expect {
      described_class.revalidate!(result, owner:, coworker:, environment:, revision:)
    }.to raise_error(Coworkers::EnvironmentRevision::InvalidTransition, /no longer authorized/)
  end
end
