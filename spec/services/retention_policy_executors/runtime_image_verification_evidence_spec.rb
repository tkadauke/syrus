require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RetentionPolicyExecutors::RuntimeImageVerificationEvidence do
  it "purges restricted artifacts while retaining the safe digest-bound attestation" do
    provider = SyntheticRuntimeImageProvider.new
    namespace = RuntimeImageNamespace.create!(name: "retention/evidence", owner_kind: "test", owner_ref: "1", provider_key: provider.key)
    image = RuntimeImages::Service.new(provider: provider).publish(namespace: namespace, source_kind: "test", source_ref: "1", platform: "linux/amd64", payload: "image")
    attempt = image.runtime_image_verification_attempts.create!(number: 1, image_digest: image.digest, state: "accepted", decision: "candidate",
      policy_snapshot: {}, policy_digest: "sha256:" + ("a" * 64), started_at: 100.days.ago, finished_at: 100.days.ago)
    evidence = attempt.create_scan_evidence!(image_digest: image.digest, scanner_name: "trivy", scanner_version: "1",
      database_version: "db", sbom_format: "cyclonedx-json", sbom_digest: "sha256:" + ("b" * 64), report_digest: "sha256:" + ("c" * 64), scanned_at: 100.days.ago)
    evidence.sbom.attach(io: StringIO.new("{}"), filename: "sbom.json", content_type: "application/json")
    evidence.scan_report.attach(io: StringIO.new("{}"), filename: "report.json", content_type: "application/json")
    attestation = attempt.create_attestation!(runtime_image: image, image_digest: image.digest, policy_digest: attempt.policy_digest,
      evidence_digest: "sha256:" + ("d" * 64), outcome: "accepted", safe_summary: { "high" => 0 }, issued_at: 100.days.ago, expires_at: 99.days.ago)
    definition = RetentionPolicyRegistry.fetch(:runtime_image_verification_evidence)

    result = described_class.new(definition).call

    expect(result.deleted_count).to eq(1)
    expect(attestation.reload).to have_attributes(safe_summary: { "high" => 0 })
    expect(attestation.exact_evidence_purged_at).to be_present
    expect(evidence.reload.sbom).not_to be_attached
    expect(evidence.scan_report).not_to be_attached
  end
end
