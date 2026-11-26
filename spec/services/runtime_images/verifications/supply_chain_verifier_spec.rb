require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RuntimeImages::Verifications::SupplyChainVerifier do
  let(:provider) { SyntheticRuntimeImageProvider.new }
  let(:namespace) { RuntimeImageNamespace.create!(name: "scan/widgets", owner_kind: "test", owner_ref: "1", provider_key: provider.key) }
  let(:service) { RuntimeImages::Service.new(provider: provider) }
  let(:image) do
    service.publish(namespace: namespace, source_kind: "test", source_ref: "revision", platform: "linux/amd64", payload: "image")
  end
  let(:scan) do
    RuntimeImages::Verifications::SupplyChainScanner::Scan.new(
      sbom: { "bomFormat" => "CycloneDX", "components" => [ { "name" => "openssl" } ] },
      report: { "Results" => [ { "Target" => "os", "Layer" => { "Digest" => "sha256:#{"1" * 64}" },
                                 "Packages" => [ { "Name" => "curl", "Layer" => { "Digest" => "sha256:#{"1" * 64}" } } ],
                                 "Vulnerabilities" => [ { "VulnerabilityID" => "CVE-1", "Severity" => "HIGH",
                                                          "Layer" => { "Digest" => "sha256:#{"1" * 64}" } } ] } ] },
      scanner_name: "trivy", scanner_version: "0.67.2", database_version: "2026-11-26T12:00:00Z", scanned_at: Time.current
    )
  end
  let(:scanner) { instance_double(RuntimeImages::Verifications::SupplyChainScanner, call: scan) }
  let(:verifier) { described_class.new(scanner: scanner) }

  def verify(policy)
    registry = RuntimeImages::Verifications::Registry.new
    registry.register("supply_chain", verifier)
    RuntimeImages::Verifications::Orchestrator.new(registry: registry, service: service).verify(
      image, policy: policy.merge("checks" => [ { "key" => "supply_chain", "required" => true } ])
    )
  end

  it "retains digest-bound SBOM, layer scan, scanner database, and strict rejection evidence" do
    attempt = verify("vulnerabilities" => { "blocked_severities" => %w[critical high] },
                     "prohibited_packages" => [ "curl" ], "exemptions" => [])

    expect(attempt).to have_attributes(state: "rejected", failure_code: "prohibited_package")
    evidence = attempt.scan_evidence
    expect(evidence).to have_attributes(image_digest: image.digest, scanner_name: "trivy", scanner_version: "0.67.2",
                                        database_version: "2026-11-26T12:00:00Z", sbom_format: "cyclonedx-json")
    expect(evidence.finding_summary).to include("high" => 1, "packages" => 1, "layers_scanned" => 1,
                                                "blocked_vulnerabilities" => 1, "prohibited_packages" => 1)
    expect(evidence.decision_evidence).to eq("blocked_vulnerability_ids" => [ "CVE-1" ], "prohibited_package_names" => [ "curl" ])
    expect(evidence.sbom).to be_attached
    expect(evidence.scan_report).to be_attached
    expect(Digest::SHA256.hexdigest(evidence.sbom.download)).to eq(evidence.sbom_digest.delete_prefix("sha256:"))
  end

  it "records only unexpired reasoned exemptions and permits the exact findings" do
    attempt = verify(
      "vulnerabilities" => { "blocked_severities" => %w[critical high] }, "prohibited_packages" => [ "curl" ],
      "exemptions" => [
        { "kind" => "vulnerability", "id" => "CVE-1", "reason" => "accepted upstream risk", "expires_at" => 1.day.from_now.iso8601 },
        { "kind" => "package", "id" => "curl", "reason" => "required health probe", "expires_at" => 1.day.from_now.iso8601 },
        { "kind" => "package", "id" => "other", "reason" => "expired", "expires_at" => 1.day.ago.iso8601 }
      ]
    )

    expect(attempt).to be_accepted
    expect(attempt.scan_evidence.exemptions.pluck("id")).to eq(%w[CVE-1 curl])
  end

  it "blocks without evidence when the scanner is unavailable" do
    allow(scanner).to receive(:call).and_raise(RuntimeImages::ProviderError, "offline")

    attempt = verify("vulnerabilities" => { "blocked_severities" => %w[critical high] })

    expect(attempt).to have_attributes(state: "blocked", failure_code: "scanner_unavailable")
    expect(attempt.scan_evidence).to be_nil
  end
end
