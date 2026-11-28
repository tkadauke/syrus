require "rails_helper"

RSpec.describe Coworkers::EnvironmentReconciler do
  let(:owner) { Factories.user }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Builder", handle: "reconcile-builder",
                                workspace_repo: "https://github.com/acme/widgets.git")
  end
  let(:environment) { Coworkers::Environment.create!(coworker: coworker, state: "building") }

  it "rejects a stale build projection with no build request" do
    revision = Coworkers::EnvironmentRevision.create!(environment: environment, number: 1, state: "building",
                                                       source_digest: "sha256:#{'a' * 64}")

    findings = described_class.new.call

    expect(findings.map(&:kind)).to include(:stale_build)
    expect(revision.reload).to be_rejected
    expect(environment.reload.last_error_code).to eq("missing_build_request")
  end

  it "revokes a candidate projection when its generic image was deleted" do
    namespace = RuntimeImageNamespace.create!(name: "coworker-reconcile", owner_kind: "coworker_environment",
                                              owner_ref: coworker.id.to_s, provider_key: "test")
    image = RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{'b' * 64}",
                                 platform: "linux/amd64", source_kind: "coworker_environment", source_ref: "revision-1",
                                 availability: "deleted", deleted_at: Time.current)
    revision = Coworkers::EnvironmentRevision.create!(environment: environment, number: 1, state: "candidate",
                                                       source_digest: "sha256:#{'c' * 64}", runtime_image: image)
    environment.update!(state: "candidate", candidate_revision: revision, candidate_runtime_image: image)

    findings = described_class.new.call

    expect(findings.map(&:kind)).to include(:image_unavailable)
    expect(revision.reload).to be_revoked
    expect(environment.reload.candidate_revision).to be_nil
  end

  it "leaves an already-terminal revision with a deleted image alone on every tick" do
    namespace = RuntimeImageNamespace.create!(name: "coworker-reconcile-terminal", owner_kind: "coworker_environment",
                                              owner_ref: coworker.id.to_s, provider_key: "test")
    deleted = RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{'d' * 64}",
                                   platform: "linux/amd64", source_kind: "coworker_environment",
                                   source_ref: "revision-1", availability: "deleted", deleted_at: Time.current)
    healthy = RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{'e' * 64}",
                                   platform: "linux/amd64", source_kind: "coworker_environment",
                                   source_ref: "revision-2", availability: "available")
    rejected = Coworkers::EnvironmentRevision.create!(environment: environment, number: 1, state: "rejected",
                                                       source_digest: "sha256:#{'f' * 64}", runtime_image: deleted)
    active = Coworkers::EnvironmentRevision.create!(environment: environment, number: 2, state: "active",
                                                     source_digest: "sha256:#{'0' * 64}", runtime_image: healthy)
    environment.update!(state: "active", active_revision: active, active_runtime_image: healthy, last_error_code: nil)
    allow(Syrus::Host::RuntimeImages).to receive(:audit).and_call_original
    allow(Syrus::Events).to receive(:publish)

    2.times { described_class.new.call }

    expect(rejected.reload).to be_rejected
    expect(environment.reload).to have_attributes(state: "active", last_error_code: nil, active_revision_id: active.id)
    expect(Syrus::Host::RuntimeImages).not_to have_received(:audit)
    expect(Syrus::Events).not_to have_received(:publish)
  end

  it "propagates an authoritative severe image revocation and terminates affected turns" do
    namespace = RuntimeImageNamespace.create!(name: "coworker-severe-reconcile", owner_kind: "coworker_environment",
                                              owner_ref: coworker.id.to_s, provider_key: "test")
    image = RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{'d' * 64}",
                                 platform: "linux/amd64", source_kind: "coworker_environment", source_ref: "revision-2",
                                 availability: "available", verification_state: "candidate", published_at: Time.current)
    revision = Coworkers::EnvironmentRevision.create!(environment: environment, number: 2, state: "active",
                                                       source_digest: "sha256:#{'e' * 64}", runtime_image: image)
    environment.update!(state: "active", active_revision: revision, active_runtime_image: image)
    provider = instance_double(RuntimeImages::Provider, revoke: nil)
    allow(Syrus::Host::AgentRuntime).to receive(:terminate_chat_processes).and_return(1)
    RuntimeImages::Service.new(provider: provider).revoke(
      image, reason: "critical_vulnerability", severity: "severe", actor: "security"
    )

    described_class.new.call

    expect(revision.reload).to be_revoked
    expect(Syrus::Host::AgentRuntime).to have_received(:terminate_chat_processes)
      .with(chat_session_ids: [], reason: "severe environment revocation: critical_vulnerability",
            runtime_image_digest: image.digest)
  end

  it "repairs drifted active pointers from immutable activation evidence while the gate is disabled" do
    namespace = RuntimeImageNamespace.create!(name: "coworker-projection-repair", owner_kind: "coworker_environment",
                                              owner_ref: coworker.id.to_s, provider_key: "test")
    image = RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{'7' * 64}",
                                 platform: "linux/amd64", source_kind: "coworker_environment", source_ref: "revision-3",
                                 availability: "available", verification_state: "candidate", published_at: Time.current)
    request = RuntimeImageBuildRequest.create!(runtime_image_namespace: namespace, state: "succeeded",
      platform: "linux/amd64", dedup_key: "projection-repair", source_kind: "coworker_environment",
      source_ref: "revision-3", source_digest: "sha256:#{'8' * 64}", recipe_digest: "sha256:#{'9' * 64}",
      requester_kind: "coworker", requester_ref: coworker.id.to_s)
    revision = Coworkers::EnvironmentRevision.create!(environment:, number: 3, state: "active",
      source_digest: request.source_digest, runtime_image: image, build_request: request)
    policy = RuntimeImages::Builds::Runner.new.verification_policy(
      request, base_policy: RuntimeImages::Verifications::Policy.current
    )
    attempt = image.runtime_image_verification_attempts.create!(number: 1, image_digest: image.digest,
      state: "accepted", decision: "candidate", policy_snapshot: policy,
      policy_digest: RuntimeImages::Verifications::CanonicalJson.digest(policy),
      started_at: Time.current, finished_at: Time.current)
    attestation = attempt.create_attestation!(runtime_image: image, image_digest: image.digest,
      policy_digest: attempt.policy_digest, evidence_digest: image.digest, outcome: "accepted",
      issued_at: Time.current, expires_at: 1.day.from_now)
    activation = environment.activations.create!(revision:, runtime_image: image,
      verification_attestation: attestation, source_digest: revision.source_digest, image_digest: image.digest,
      authority_kind: "permission", actor: "operator", activated_at: Time.current)
    environment.update!(state: "failed", active_activation: activation, active_revision: nil,
                        active_runtime_image: nil, last_error_code: "partial_write")

    findings = described_class.new.call

    expect(findings.map(&:kind)).to include(:activation_projection_repaired)
    expect(environment.reload).to have_attributes(state: "active", active_revision_id: revision.id,
      active_runtime_image_id: image.id, last_error_code: nil)
    expect(RuntimeImageAuditEvent.where(event_type: "coworker_environment.projection_repaired",
                                        outcome: "repaired")).to exist
  end
end
