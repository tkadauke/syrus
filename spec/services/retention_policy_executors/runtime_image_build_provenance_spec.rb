require "rails_helper"

RSpec.describe RetentionPolicyExecutors::RuntimeImageBuildProvenance do
  let(:digest) { "sha256:#{"a" * 64}" }
  let(:namespace) { RuntimeImageNamespace.create!(name: "retention/build", owner_kind: "test", owner_ref: "1", provider_key: "test") }
  let(:request) do
    RuntimeImageBuildRequest.create!(
      runtime_image_namespace: namespace, state: "failed", platform: "linux/amd64",
      dedup_key: "retention-build", source_kind: "test", source_ref: "source", source_digest: digest,
      recipe_digest: digest, requester_kind: "test", requester_ref: "1", finished_at: 200.days.ago
    )
  end

  it "purges expired source and log payloads while retaining their safe metadata" do
    RetentionPolicySetting.for(RetentionPolicyRegistry.fetch(:runtime_image_build_provenance))
      .update!(retention_seconds: 180.days.to_i)
    request.source_archive.attach(io: StringIO.new("source"), filename: "source.tar", content_type: "application/x-tar")
    attempt = request.attempts.create!(number: 1, state: "failed", started_at: 200.days.ago, finished_at: 200.days.ago)
    evidence = RuntimeImageBuildEvidence.create!(
      request: request, attempt: attempt, outcome: "failed", source_digest: digest,
      log: "restricted build output", log_bytes: 23, finished_at: 200.days.ago
    )

    result = RetentionPolicyRegistry.fetch(:runtime_image_build_provenance).executor.call

    expect(result.deleted_count).to eq(2)
    expect(request.reload.source_archive).not_to be_attached
    expect(evidence.reload).to have_attributes(log: nil, log_bytes: 23, source_digest: digest)
    expect(RuntimeImageBuildRequest.exists?(request.id)).to be(true)
  end

  it "keeps source and log payloads inside the retention window" do
    RetentionPolicySetting.for(RetentionPolicyRegistry.fetch(:runtime_image_build_provenance))
      .update!(retention_seconds: 180.days.to_i)
    request.update_columns(finished_at: 10.days.ago)
    request.source_archive.attach(io: StringIO.new("source"), filename: "source.tar", content_type: "application/x-tar")
    attempt = request.attempts.create!(number: 1, state: "failed", started_at: 10.days.ago, finished_at: 10.days.ago)
    evidence = RuntimeImageBuildEvidence.create!(
      request: request, attempt: attempt, outcome: "failed", source_digest: digest,
      log: "recent", log_bytes: 6, finished_at: 10.days.ago
    )

    result = RetentionPolicyRegistry.fetch(:runtime_image_build_provenance).executor.call

    expect(result.deleted_count).to eq(0)
    expect(request.reload.source_archive).to be_attached
    expect(evidence.reload.log).to eq("recent")
  end
end
