require "rails_helper"

RSpec.describe Coworkers::EnvironmentCompatibilityRebuild do
  let(:owner) { Factories.user }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Builder", handle: "compat-builder",
      workspace_repo: "https://example.test/builder.git")
  end
  let(:environment) { Coworkers::Environment.create!(coworker:, state: "active") }
  let(:namespace) do
    RuntimeImageNamespace.create!(name: "compat-rebuild", owner_kind: "coworker_environment",
      owner_ref: coworker.id.to_s, provider_key: "synthetic")
  end
  let(:image) do
    RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{'a' * 64}",
      platform: "linux/amd64", source_kind: "coworker_environment", source_ref: "active",
      availability: "available", verification_state: "candidate")
  end
  let(:base_image) do
    RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{'b' * 64}",
      platform: "linux/amd64", source_kind: RuntimeImages::CoworkerBase::SOURCE_KIND,
      source_ref: "base", availability: "available", verification_state: "candidate")
  end
  let(:replacement) do
    CoworkerBaseRelease.create!(runtime_image: base_image, platform: "linux/amd64", status: "active",
      active_key: "linux/amd64", generation: 2, runtime_abi: 3, compat_min: 2, compat_max: 4,
      promoted_at: Time.current)
  end
  let(:replacement_base) do
    RuntimeImages::BuildRequests::Base.new(id: replacement.id, digest: replacement.digest,
      runtime_abi: replacement.runtime_abi, compat_min: replacement.compat_min, compat_max: replacement.compat_max)
  end
  let!(:active) do
    environment.revisions.create!(number: 1, state: "active", source_digest: "sha256:#{'c' * 64}",
      source_manifest: { "files" => { "environment/Dockerfile" => { "content" => "FROM base" } } },
      runtime_image: image).tap do |revision|
      environment.update!(active_revision: revision, active_runtime_image: image)
    end
  end

  before do
    Feature.create!(slug: "coworker_custom_environments", category: "Labs", name: "x",
      enabled: true, experimental: true)
    allow(AppSetting).to receive(:beta_mode_enabled?).and_return(true)
    allow(Syrus::Host::RuntimeImages).to receive(:base_for_rebuild).with(replacement.id).and_return(replacement_base)
  end

  it "requests an unchanged-source candidate while preserving the active digest" do
    request = instance_double(Coworkers::EnvironmentBuildRequest)
    allow(Coworkers::EnvironmentBuildRequest).to receive(:new).with(coworker, nil).and_return(request)
    allow(request).to receive(:call_revision)

    described_class.new(runtime_image_id: image.id, replacement_base_release_id: replacement.id,
      reasons: [ "support_ended" ]).call

    rebuilt = environment.revisions.order(:number).last
    expect(rebuilt).to have_attributes(state: "draft", source_digest: active.source_digest,
      source_manifest: active.source_manifest)
    expect(request).to have_received(:call_revision).with(rebuilt, base: replacement_base,
      reason: "compatibility rebuild: support_ended")
    expect(environment.reload).to have_attributes(state: "active", active_revision_id: active.id,
      active_runtime_image_id: image.id)
  end

  it "deduplicates a rebuild already targeting the replacement base" do
    existing = environment.revisions.create!(number: 2, state: "building", source_digest: active.source_digest,
      source_manifest: active.source_manifest, coworker_base_release_id: replacement.id,
      runtime_abi: 3, compat_min: 2, compat_max: 4, recipe_digest: "sha256:#{'d' * 64}")
    request = instance_double(Coworkers::EnvironmentBuildRequest, call_revision: nil)
    allow(Coworkers::EnvironmentBuildRequest).to receive(:new).and_return(request)

    expect {
      described_class.new(runtime_image_id: image.id, replacement_base_release_id: replacement.id,
        reasons: [ "provider_upgrade" ]).call
    }.not_to change(environment.revisions, :count)
    expect(request).to have_received(:call_revision).with(existing, base: replacement_base,
      reason: "compatibility rebuild: provider_upgrade")
  end

  it "deduplicates an unchanged-source draft created by an overlapping request" do
    existing = environment.revisions.create!(number: 2, state: "draft",
      source_digest: active.source_digest, source_manifest: active.source_manifest)
    request = instance_double(Coworkers::EnvironmentBuildRequest, call_revision: nil)
    allow(Coworkers::EnvironmentBuildRequest).to receive(:new).and_return(request)

    expect {
      described_class.new(runtime_image_id: image.id, replacement_base_release_id: replacement.id,
        reasons: [ "provider_contract_outdated" ]).call
    }.not_to change(environment.revisions, :count)
    expect(request).to have_received(:call_revision).with(existing, base: replacement_base,
      reason: "compatibility rebuild: provider_contract_outdated")
  end
end
