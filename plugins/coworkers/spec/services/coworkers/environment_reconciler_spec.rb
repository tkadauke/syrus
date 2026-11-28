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
end
