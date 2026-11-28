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
end
