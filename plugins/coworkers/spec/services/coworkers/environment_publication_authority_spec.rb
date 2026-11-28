require "rails_helper"

RSpec.describe Coworkers::EnvironmentPublicationAuthority do
  let(:owner) { Factories.user }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Publisher", handle: "environment-publisher",
                                workspace_repo: "https://github.com/acme/widgets.git")
  end
  let(:environment) { Coworkers::Environment.create!(coworker:, state: "candidate") }
  let(:namespace) do
    RuntimeImageNamespace.create!(name: "publication-authority", owner_kind: "coworker_environment",
                                  owner_ref: coworker.id.to_s, provider_key: "test")
  end
  let(:image) do
    RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{'a' * 64}",
                         platform: "linux/amd64", source_kind: "coworker_environment", source_ref: "revision-1",
                         availability: "available", verification_state: "candidate", published_at: Time.current)
  end
  let(:revision) do
    Coworkers::EnvironmentRevision.create!(environment:, number: 1, state: "candidate",
                                           source_digest: "sha256:#{'b' * 64}", runtime_image: image)
  end
  let!(:attempt) do
    RuntimeImageVerificationAttempt.create!(runtime_image: image, number: 1, image_digest: image.digest,
      state: "accepted", decision: "candidate", policy_snapshot: {}, policy_digest: "sha256:#{'c' * 64}",
      started_at: 1.minute.ago, finished_at: Time.current)
  end
  before do
    Feature.create!(slug: "coworker_custom_environments", category: "Labs", name: "x", enabled: true, experimental: true)
    allow(AppSetting).to receive(:beta_mode_enabled?).and_return(true)
    environment.update!(candidate_revision: revision, candidate_runtime_image: image)
  end

  it "computes a complete evidence-bound subject and returns a scoped allow grant" do
    expiry = 20.minutes.from_now
    allow(Syrus::Host::PermissionAuthorization).to receive(:call)
      .and_return(Syrus::Host::PermissionAuthorization::Result.new(decision: :allow, lease_expires_at: expiry))

    result = described_class.new(environment).call(revision)

    expect(result).to be_allowed
    expect(result.subject).to have_attributes(environment_id: environment.id, revision_id: revision.id,
                                              source_digest: revision.source_digest, image_digest: image.digest,
                                              policy_result: "candidate")
    expect(result.subject.risk_deltas.keys).to contain_exactly(
      "source", "base", "dependencies", "sbom", "vulnerabilities", "secrets", "network", "policy"
    )
    expect(result.grant).to have_attributes(environment_id: environment.id, revision_id: revision.id,
                                            expires_at: expiry, decision: :allow)
    expect(described_class.new(environment).valid_grant?(result.grant, revision)).to be(true)
  end

  it "returns a reviewable pending publication action for ask without activating anything" do
    allow(Syrus::Host::PermissionAuthorization).to receive(:call)
      .and_return(Syrus::Host::PermissionAuthorization::Result.new(decision: :ask, lease_expires_at: nil))

    result = described_class.new(environment).call(revision)

    expect(result).to be_ask
    expect(result.grant).to be_nil
    expect(result.pending_action).to include(
      "action" => "publish_coworker_environment", "status" => "pending",
      "revision_id" => revision.id, "image_digest" => image.digest,
      "risk_summary" => hash_including("changed_areas")
    )
    expect(environment.reload.active_revision).to be_nil
    expect(revision.reload).to be_candidate
  end

  it "returns deny without a grant or pending action" do
    allow(Syrus::Host::PermissionAuthorization).to receive(:call)
      .and_return(Syrus::Host::PermissionAuthorization::Result.new(decision: :deny, lease_expires_at: nil))

    result = described_class.new(environment).call(revision)

    expect(result).to be_denied
    expect(result.grant).to be_nil
    expect(result.pending_action).to be_nil
  end

  it "rejects expired and evidence-stale grants" do
    allow(Syrus::Host::PermissionAuthorization).to receive(:call)
      .and_return(Syrus::Host::PermissionAuthorization::Result.new(decision: :allow, lease_expires_at: nil))
    grant = described_class.new(environment).call(revision).grant

    expired = grant.with(expires_at: 1.second.ago)
    stale = grant.with(fingerprint: "sha256:stale")
    expect(described_class.new(environment).valid_grant?(expired, revision)).to be(false)
    expect(described_class.new(environment).valid_grant?(stale, revision)).to be(false)
  end

  it "does not evaluate publication authority for an unverified build output" do
    allow(Syrus::Host::PermissionAuthorization).to receive(:call)
    attempt.update!(state: "blocked", decision: "blocked")

    expect { described_class.new(environment).call(revision) }
      .to raise_error(Coworkers::EnvironmentRevision::InvalidTransition, /exact verified candidate/)
    expect(Syrus::Host::PermissionAuthorization).not_to have_received(:call)
  end
end
