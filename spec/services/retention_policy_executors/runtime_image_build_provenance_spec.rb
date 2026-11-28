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

  it "prunes only superseded verification attempts outside the retention window" do
    RetentionPolicySetting.for(RetentionPolicyRegistry.fetch(:runtime_image_build_provenance))
      .update!(retention_seconds: 180.days.to_i)
    image = RuntimeImage.create!(
      runtime_image_namespace: namespace, digest: digest, source_kind: "test", source_ref: "retention"
    )
    old = image.runtime_image_verification_attempts.create!(
      number: 1, image_digest: digest, policy_digest: digest, state: "rejected",
      started_at: 200.days.ago, finished_at: 200.days.ago
    )
    check = old.checks.create!(position: 0, verifier_key: "retention", state: "failed")
    scan = RuntimeImageScanEvidence.create!(
      attempt: old, image_digest: digest, scanner_name: "scanner", scanner_version: "1",
      database_version: "1", sbom_format: "cyclonedx", sbom_digest: digest,
      report_digest: digest, scanned_at: 200.days.ago
    )
    policy = RuntimeImagePolicyEvidence.create!(
      attempt: old, image_digest: digest, report_digest: digest, scanned_at: 200.days.ago
    )
    attestation = RuntimeImageVerificationAttestation.create!(
      runtime_image: image, attempt: old, image_digest: digest, policy_digest: digest,
      evidence_digest: digest, outcome: "rejected", issued_at: 200.days.ago, expires_at: 190.days.ago
    )
    recent = image.runtime_image_verification_attempts.create!(
      number: 2, image_digest: digest, policy_digest: digest, state: "rejected",
      started_at: 10.days.ago, finished_at: 10.days.ago
    )
    latest = image.runtime_image_verification_attempts.create!(
      number: 3, image_digest: digest, policy_digest: digest, state: "accepted",
      started_at: 200.days.ago, finished_at: 200.days.ago
    )

    result = RetentionPolicyRegistry.fetch(:runtime_image_build_provenance).executor.call

    expect(result.deleted_count).to eq(1)
    expect(RuntimeImageVerificationAttempt.exists?(old.id)).to be(false)
    expect(RuntimeImageVerificationCheck.exists?(check.id)).to be(false)
    expect(RuntimeImageScanEvidence.exists?(scan.id)).to be(false)
    expect(RuntimeImagePolicyEvidence.exists?(policy.id)).to be(false)
    expect(RuntimeImageVerificationAttestation.exists?(attestation.id)).to be(false)
    expect(RuntimeImageVerificationAttempt.exists?(recent.id)).to be(true)
    expect(RuntimeImageVerificationAttempt.exists?(latest.id)).to be(true)
  end
end
