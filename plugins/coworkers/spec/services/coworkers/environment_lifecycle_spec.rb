require "rails_helper"

RSpec.describe Coworkers::EnvironmentLifecycle do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Lifecycle", handle: "env-lifecycle",
                                workspace_repo: repository.remote_url)
  end
  let(:environment) { Coworkers::Environment.create!(coworker: coworker, state: "building") }
  let(:namespace) do
    RuntimeImageNamespace.create!(name: "coworker-env-lifecycle", owner_kind: "coworker_environment",
                                  owner_ref: coworker.id, provider_key: "synthetic")
  end
  let(:image) do
    RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{'b' * 64}", platform: "linux/amd64",
                         source_kind: "coworker_environment", source_ref: "revision-1", availability: "available")
  end

  def revision(number: 1, state: "building", digest: "a")
    Coworkers::EnvironmentRevision.create!(environment: environment, number: number, state: state,
                                           source_digest: "sha256:#{digest * 64}")
  end

  before do
    Feature.create!(slug: "coworker_custom_environments", category: "Labs", name: "x", enabled: true,
                    experimental: true)
    allow(AppSetting).to receive(:beta_mode_enabled?).and_return(true)
    allow(Syrus::Host::RuntimeImages).to receive(:revoke) { |record, reason:| record.mark_revoked!(reason: reason) }
  end

  it "promotes a verified candidate, retires the previous publication, and audits every transition" do
    old_image = RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{'d' * 64}", platform: "linux/amd64",
                                     source_kind: "coworker_environment", source_ref: "revision-0", availability: "available")
    old = revision(state: "verified")
    old.update!(runtime_image: old_image)
    described_class.new.candidate!(revision(number: 2, digest: "c"), image)
    candidate = environment.revisions.find_by!(number: 2)
    described_class.new.verified!(candidate)
    described_class.new.publish!(old)
    described_class.new.publish!(candidate, actor: "operator")

    expect(old.reload).to be_retired
    expect(candidate.reload).to be_published
    expect(environment.reload).to have_attributes(state: "active", active_revision_id: candidate.id,
                                                   active_runtime_image_id: image.id, candidate_revision_id: nil)
    expect(RuntimeImageAuditEvent.where(event_type: %w[environment.candidate environment.verified environment.published environment.retired]).count).to eq(5)
  end

  it "fails publication closed when the feature gate is disabled" do
    record = revision(state: "verified")
    Feature.find_by!(slug: "coworker_custom_environments").update!(enabled: false)

    expect { described_class.new.publish!(record) }.to raise_error(Coworkers::EnvironmentBuildRequest::Disabled)
    expect(record.reload).to be_verified
  end

  it "clears active pointers when an image becomes incompatible, revoked, or deleted" do
    record = revision(state: "verified")
    record.update!(runtime_image: image)
    described_class.new.publish!(record)

    described_class.new.incompatible!(record)
    expect(environment.reload).to have_attributes(state: "incompatible", active_revision_id: nil)
    expect(record.reload).to be_incompatible
    described_class.new.revoke!(record, reason: "security")
    expect(image.reload).to be_revoked
    described_class.new.deleted!(record)
    expect(record.reload).to be_deleted
  end

  it "retires a publication when its coworker is disabled without deleting audit history" do
    record = revision(state: "verified")
    record.update!(runtime_image: image)
    described_class.new.publish!(record)

    coworker.update!(state: "paused")

    expect(record.reload).to be_retired
    expect(environment.reload).to have_attributes(state: "draft", active_revision_id: nil,
                                                   last_error_code: "coworker_disabled")
    expect(RuntimeImageAuditEvent.where(event_type: "environment.coworker_disabled")).to exist
  end
end
