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
    RuntimeImageBuildResult.create!(request: request, runtime_image: image, outcome: "succeeded", finished_at: Time.current)
  end

  it "projects a verified successful build into a candidate" do
    described_class.new(environment).reconcile_build!(revision)

    expect(revision.reload).to have_attributes(state: "candidate", runtime_image_id: image.id)
    expect(environment.reload).to have_attributes(state: "candidate", candidate_revision_id: revision.id,
                                                   candidate_runtime_image_id: image.id, last_error_code: nil)
    expect(RuntimeImageAuditEvent.where(event_type: "coworker_environment.verified", runtime_image_id: image.id)).to exist
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
  end

  it "rejects a succeeded build whose image record is missing" do
    request.result.destroy!

    described_class.new(environment).reconcile_build!(revision)

    expect(revision.reload).to be_rejected
    expect(environment.reload).to have_attributes(state: "failed", last_error_code: "missing_image_record")
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
  end

  it "fails closed when the image ABI is incompatible" do
    allow(Syrus::Host::RuntimeImages).to receive(:active_base).and_return(base.with(runtime_abi: 9))

    described_class.new(environment).reconcile_build!(revision)

    expect(revision.reload).to be_rejected
    expect(environment.reload.last_error_code).to eq(described_class::INCOMPATIBLE)
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
end
