require "rails_helper"

RSpec.describe "runtime-image build artifact retention" do
  let(:namespace) { RuntimeImageNamespace.create!(name: "retention/builds", owner_kind: "test", owner_ref: "1", provider_key: "synthetic") }
  let(:request) do
    RuntimeImageBuildRequest.create!(
      runtime_image_namespace: namespace, state: "failed", platform: "linux/amd64", dedup_key: SecureRandom.hex(16),
      source_kind: "test", source_ref: "one", source_digest: digest("source"), source_manifest: {},
      recipe_digest: digest("recipe"), recipe: {}, requester_kind: "test", requester_ref: "1",
      max_attempts: 1, finished_at: 40.days.ago
    )
  end
  let(:attempt) do
    request.attempts.create!(number: 1, state: "failed", worker_hostname: "worker",
      started_at: 40.days.ago, finished_at: 40.days.ago)
  end

  def digest(value) = "sha256:#{Digest::SHA256.hexdigest(value)}"

  it "purges expired source archives while retaining the build request and digest" do
    definition = RetentionPolicyRegistry.fetch(:runtime_image_build_source)
    RetentionPolicySetting.for(definition).update!(retention_seconds: 30.days.to_i)
    request.source_archive.attach(io: StringIO.new("source"), filename: "source.tar", content_type: "application/x-tar")

    result = definition.executor.call

    expect(result.deleted_count).to eq(1)
    expect(request.reload).to have_attributes(source_digest: digest("source"))
    expect(request.source_archive).not_to be_attached
  end

  it "purges expired restricted log text while retaining safe build evidence" do
    definition = RetentionPolicyRegistry.fetch(:runtime_image_build_log)
    RetentionPolicySetting.for(definition).update!(retention_seconds: 30.days.to_i)
    evidence = RuntimeImageBuildEvidence.create!(
      request: request, attempt: attempt, outcome: "failed", source_digest: request.source_digest,
      log: "restricted output", log_bytes: 17, finished_at: 40.days.ago
    )

    result = definition.executor.call

    expect(result.deleted_count).to eq(1)
    expect(evidence.reload).to have_attributes(log: nil, log_bytes: 17, source_digest: request.source_digest)
  end
end
