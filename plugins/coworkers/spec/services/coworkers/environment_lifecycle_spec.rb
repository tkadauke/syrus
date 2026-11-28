require "rails_helper"

RSpec.describe Coworkers::EnvironmentLifecycle do
  let(:owner) { Factories.user }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Builder", handle: "lifecycle-builder",
                                workspace_repo: "https://github.com/acme/widgets.git")
  end
  let(:environment) { Coworkers::Environment.create!(coworker: coworker, state: "building") }
  let(:namespace) do
    RuntimeImageNamespace.create!(name: "coworker-lifecycle", owner_kind: "coworker_environment",
                                  owner_ref: coworker.id.to_s, provider_key: "test")
  end
  let(:image) do
    RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{'a' * 64}",
                         platform: "linux/amd64", source_kind: "coworker_environment", source_ref: "revision-1",
                         availability: "available", published_at: Time.current)
  end
  let(:request) do
    RuntimeImageBuildRequest.create!(runtime_image_namespace: namespace, state: "succeeded", platform: "linux/amd64",
                                     dedup_key: "dedup", source_kind: "coworker_environment", source_ref: "revision-1",
                                     source_digest: "sha256:#{'b' * 64}", recipe_digest: "sha256:#{'c' * 64}",
                                     requester_kind: "coworker", requester_ref: coworker.id.to_s)
  end
  let(:revision) do
    Coworkers::EnvironmentRevision.create!(environment: environment, number: 1, state: "verifying",
                                           source_digest: "sha256:#{'d' * 64}", runtime_abi: 3,
                                           compat_min: 2, compat_max: 4, build_request: request)
  end
  let(:base) { RuntimeImages::BuildRequests::Base.new(id: 1, digest: "sha256:#{'e' * 64}", runtime_abi: 3, compat_min: 2, compat_max: 4) }

  before do
    Feature.create!(slug: "coworker_custom_environments", category: "Labs", name: "x", enabled: true, experimental: true)
    allow(AppSetting).to receive(:beta_mode_enabled?).and_return(true)
    allow(Syrus::Host::RuntimeImages).to receive(:active_base).and_return(base)
    allow(Syrus::Host::RuntimeImages).to receive(:retain)
    allow(Syrus::Events).to receive(:publish)
    RuntimeImageBuildResult.create!(request: request, runtime_image: image, outcome: "succeeded", finished_at: Time.current)
  end

  it "projects a verified successful build into a candidate" do
    described_class.new(environment).reconcile_build!(revision)

    expect(revision.reload).to have_attributes(state: "candidate", runtime_image_id: image.id)
    expect(environment.reload).to have_attributes(state: "candidate", candidate_revision_id: revision.id,
                                                   candidate_runtime_image_id: image.id, last_error_code: nil)
    expect(RuntimeImageAuditEvent.where(event_type: "coworker_environment.verified", runtime_image_id: image.id)).to exist
    expect(Syrus::Events).to have_received(:publish).with(
      "coworker_environment.candidate", hash_including(coworker_id: coworker.id, revision_id: revision.id,
                                                        inspection: hash_including("v" => 1, "state" => "candidate"))
    )
  end

  it "publishes atomically and retires the previous active revision" do
    previous = Coworkers::EnvironmentRevision.create!(environment: environment, number: 2, state: "active",
                                                       source_digest: "sha256:#{'f' * 64}", runtime_image: image)
    described_class.new(environment).reconcile_build!(revision)
    environment.update!(state: "candidate", active_revision: previous, active_runtime_image: image)

    described_class.new(environment).publish!(revision, actor: "operator")

    expect(previous.reload).to be_retired
    expect(revision.reload).to be_active
    expect(environment.reload).to have_attributes(state: "active", active_revision_id: revision.id,
                                                   candidate_revision_id: nil)
    expect(Syrus::Host::RuntimeImages).to have_received(:retain).with(image, reason: "active coworker environment", actor: "operator")
    expect(Syrus::Events).to have_received(:publish).with(
      "coworker_environment.activated", hash_including(revision_id: revision.id,
                                                        inspection: hash_including("active_digest" => image.digest))
    )
  end

  it "rejects a succeeded build whose image record is missing" do
    request.result.destroy!

    described_class.new(environment).reconcile_build!(revision)

    expect(revision.reload).to be_rejected
    expect(environment.reload).to have_attributes(state: "failed", last_error_code: "missing_image_record")
    expect(Syrus::Events).to have_received(:publish).with(
      "coworker_environment.rejected", hash_including(revision_id: revision.id)
    )
  end

  it "keeps the current active image selected when a replacement build fails" do
    active = Coworkers::EnvironmentRevision.create!(environment: environment, number: 2, state: "active",
                                                     source_digest: "sha256:#{'f' * 64}", runtime_image: image)
    environment.update!(active_revision: active, active_runtime_image: image)
    request.result.destroy!
    request.update!(state: "failed")
    RuntimeImageBuildResult.create!(request: request, outcome: "failed", error_code: "builder_failed", finished_at: Time.current)

    described_class.new(environment).reconcile_build!(revision)

    expect(revision.reload).to be_rejected
    expect(environment.reload).to have_attributes(state: "active", active_revision_id: active.id,
                                                   last_error_code: "builder_failed")
    expect(Syrus::Events).to have_received(:publish).with(
      "coworker_environment.build_failed", hash_including(revision_id: revision.id)
    )
  end

  it "persists the rejection when publishing a candidate that became incompatible" do
    described_class.new(environment).reconcile_build!(revision)
    allow(Syrus::Host::RuntimeImages).to receive(:active_base).and_return(base.with(runtime_abi: 9))

    expect { described_class.new(environment).publish!(revision, actor: "operator") }
      .to raise_error(Coworkers::EnvironmentRevision::InvalidTransition)

    expect(revision.reload).to be_rejected
    expect(environment.reload).to have_attributes(state: "failed", candidate_revision_id: nil,
                                                   last_error_code: described_class::INCOMPATIBLE)
  end

  it "fails closed when the image ABI is incompatible" do
    allow(Syrus::Host::RuntimeImages).to receive(:active_base).and_return(base.with(runtime_abi: 9))

    described_class.new(environment).reconcile_build!(revision)

    expect(revision.reload).to be_rejected
    expect(environment.reload.last_error_code).to eq(described_class::INCOMPATIBLE)
    expect(Syrus::Events).to have_received(:publish).with(
      "coworker_environment.rejected", hash_including(revision_id: revision.id)
    )
  end

  it "retires pointers on disable without deleting generic image history" do
    revision.update!(state: "active", runtime_image: image)
    environment.update!(state: "active", active_revision: revision, active_runtime_image: image)

    described_class.new(environment).disable!(actor: "plugin_disable")

    expect(revision.reload).to be_retired
    expect(environment.reload).to have_attributes(state: "revoked", active_revision_id: nil,
                                                   last_error_code: "coworker_disabled")
    expect(image.reload).to be_available
  end

  it "retires a verified candidate on disable instead of orphaning it" do
    revision.update!(state: "candidate", runtime_image: image)
    environment.update!(state: "candidate", candidate_revision: revision, candidate_runtime_image: image)

    described_class.new(environment).disable!(actor: "plugin_disable")

    expect(revision.reload).to be_retired
    expect(environment.reload).to have_attributes(state: "revoked", candidate_revision_id: nil)
    expect(RuntimeImageAuditEvent.where(event_type: "coworker_environment.disabled")).to exist
  end

  it "rejects a successful build projection when its image was deleted" do
    image.mark_deleted!

    described_class.new(environment).reconcile_build!(revision)

    expect(revision.reload).to be_rejected
    expect(environment.reload).to have_attributes(state: "revoked", last_error_code: "image_deleted")
    expect(RuntimeImageAuditEvent.where(event_type: "coworker_environment.revoked", runtime_image_id: image.id)).to exist
    expect(Syrus::Events).to have_received(:publish).with(
      "coworker_environment.revoked", hash_including(revision_id: revision.id)
    )
  end

  it "keeps the previous active revision selected when a replacement candidate is revoked" do
    active_image = RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{'f' * 64}",
                                        platform: "linux/amd64", source_kind: "coworker_environment",
                                        source_ref: "revision-previous", availability: "available",
                                        published_at: Time.current)
    active = Coworkers::EnvironmentRevision.create!(environment: environment, number: 2, state: "active",
                                                     source_digest: "sha256:#{'f' * 64}", runtime_image: active_image)
    revision.update!(state: "candidate", runtime_image: image)
    environment.update!(state: "candidate", active_revision: active, active_runtime_image: active_image,
                        candidate_revision: revision, candidate_runtime_image: image)
    image.mark_deleted!

    described_class.new(environment).revoke!(revision, reason: "image_deleted")

    expect(revision.reload).to be_revoked
    expect(environment.reload).to have_attributes(state: "active", active_revision_id: active.id,
                                                   active_runtime_image_id: active_image.id,
                                                   candidate_revision_id: nil, candidate_runtime_image_id: nil)
  end

  it "retains image history and audits ownership removal before deleting plugin rows" do
    revision.update!(state: "candidate", runtime_image: image)

    expect { coworker.destroy! }
      .to change { RuntimeImageAuditEvent.where(event_type: "coworker_environment.owner_removed").count }.by(1)
    expect(Syrus::Host::RuntimeImages).to have_received(:retain)
      .with(image, reason: "coworker environment audit history", actor: "coworker_removal")
    expect(image.reload).to be_available
  end
end
