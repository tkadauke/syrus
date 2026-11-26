require "rails_helper"

RSpec.describe Coworkers::EnvironmentReconciler do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Reconciler", handle: "env-reconciler",
                                workspace_repo: repository.remote_url)
  end
  let(:environment) { Coworkers::Environment.create!(coworker: coworker, state: "building") }
  let(:namespace) do
    RuntimeImageNamespace.create!(name: "coworker-env-reconciler", owner_kind: "coworker_environment",
                                  owner_ref: coworker.id, provider_key: "synthetic")
  end

  def request(state:, result: nil)
    record = RuntimeImageBuildRequest.create!(runtime_image_namespace: namespace, state: state, platform: "linux/amd64",
      dedup_key: SecureRandom.hex, source_kind: "coworker_environment", source_ref: SecureRandom.hex,
      source_digest: "sha256:#{'a' * 64}", recipe_digest: "sha256:#{'b' * 64}", recipe: {},
      requester_kind: "coworker", requester_ref: coworker.id, max_attempts: 1)
    RuntimeImageBuildResult.create!(request: record, finished_at: Time.current, **result) if result
    record
  end

  def revision(build_request:, state: "building", image: nil)
    Coworkers::EnvironmentRevision.create!(environment: environment, number: environment.next_revision_number,
      state: state, source_digest: "sha256:#{SecureRandom.hex(32)}", build_request: build_request, runtime_image: image)
  end

  it "projects a successful generic build through candidate and verified" do
    image = RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{'c' * 64}", platform: "linux/amd64",
      source_kind: "coworker_environment", source_ref: "revision", availability: "available")
    build = request(state: "succeeded", result: { outcome: "succeeded", runtime_image: image, digest: image.digest })
    record = revision(build_request: build)

    described_class.new.call

    expect(record.reload).to have_attributes(state: "verified", runtime_image_id: image.id)
    expect(environment.reload).to have_attributes(state: "candidate", candidate_revision_id: record.id,
                                                   candidate_runtime_image_id: image.id)
  end

  it "rejects deterministic build rejection and fails an abandoned stale build" do
    rejected = revision(build_request: request(state: "rejected", result: { outcome: "rejected", error_code: "policy" }))
    stale_request = request(state: "building")
    stale = revision(build_request: stale_request)
    stale.update_column(:updated_at, 2.hours.ago)

    described_class.new(now: Time.current).call

    expect(rejected.reload).to be_rejected
    expect(stale.reload).to be_build_failed
  end

  it "marks a revision deleted when its image record is missing" do
    record = revision(build_request: request(state: "failed", result: { outcome: "failed" }), state: "verified")
    record.update_column(:runtime_image_id, 999_999)

    described_class.new.call

    expect(record.reload).to be_deleted
    expect(environment.reload.state).to eq("deleted")
  end

  it "uses the consumed cleanup queue" do
    expect(Coworkers::EnvironmentReconcileJob.new.queue_name).to eq("cleanup")
  end
end
