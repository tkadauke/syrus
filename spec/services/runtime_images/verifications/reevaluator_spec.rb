require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RuntimeImages::Verifications::Reevaluator do
  let(:provider) { SyntheticRuntimeImageProvider.new }
  let(:namespace) { RuntimeImageNamespace.create!(name: "reevaluate/widgets", owner_kind: "test", owner_ref: "1", provider_key: provider.key) }
  let(:service) { RuntimeImages::Service.new(provider: provider) }
  let(:image) do
    service.publish(namespace: namespace, source_kind: "test", source_ref: "revision", platform: "linux/amd64", payload: "image")
  end
  let(:policy) { { "checks" => [ { "key" => "scan", "required" => true } ], "evidence_ttl_seconds" => 3600 } }
  let(:registry) { RuntimeImages::Verifications::Registry.new }
  let(:orchestrator) { RuntimeImages::Verifications::Orchestrator.new(registry: registry, service: service) }

  def pass_result
    RuntimeImages::Verifications::Result.pass(evidence_references: [ { "kind" => "scan", "digest" => image.digest } ])
  end

  it "does nothing while the digest-bound attestation is current" do
    registry.register("scan", ->(**) { pass_result })
    orchestrator.verify(image, policy: policy)

    expect(described_class.new(orchestrator: orchestrator, policy: policy).call(image)).to be_nil
    expect(image.runtime_image_verification_attempts.count).to eq(1)
  end

  it "re-evaluates expired evidence and emits a safe revocation candidate for a published image" do
    registry.register("scan", ->(**) { pass_result })
    previous = orchestrator.verify(image, policy: policy, now: 2.hours.ago)
    registry.register("scan", ->(**) {
      RuntimeImages::Verifications::Result.fail(failure_class: :policy, code: :blocked_vulnerability,
        message: "restricted finding", evidence_references: [ { "kind" => "restricted", "digest" => image.digest } ])
    })

    attempt = described_class.new(orchestrator: orchestrator, policy: policy).call(image)

    expect(previous.reload).to be_accepted
    expect(attempt).to have_attributes(state: "rejected", failure_code: "blocked_vulnerability")
    expect(image.reload).to be_available
    expect(image).not_to be_pullable
    expect(attempt.revocation_candidate).to have_attributes(trigger_kind: "attestation_expired", severity: "high", state: "open")
    expect(attempt.revocation_candidate.reason).not_to include("restricted finding")
  end

  it "re-evaluates when policy changes before expiry" do
    registry.register("scan", ->(**) { pass_result })
    orchestrator.verify(image, policy: policy)
    changed = policy.deep_merge("vulnerabilities" => { "blocked_severities" => %w[critical high] })

    expect(described_class.new(orchestrator: orchestrator, policy: changed).call(image)).to be_accepted
    expect(image.runtime_image_verification_attempts.count).to eq(2)
  end

  it "re-evaluates when vulnerability data advances before expiry" do
    registry.register("scan", ->(**) { pass_result })
    attempt = orchestrator.verify(image, policy: policy)
    attempt.create_scan_evidence!(image_digest: image.digest, scanner_name: "scanner", scanner_version: "1",
                                  database_version: "old", sbom_format: "cyclonedx-json",
                                  sbom_digest: "sha256:#{"a" * 64}", report_digest: "sha256:#{"b" * 64}",
                                  scanned_at: Time.current)

    expect(described_class.new(orchestrator: orchestrator, policy: policy).call(image, database_version: "new")).to be_accepted
  end
end
