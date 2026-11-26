module RuntimeImages
  module Verifications
    class SupplyChainVerifier
      def initialize(scanner: SupplyChainScanner.new)
        @scanner = scanner
      end

      def call(image:, policy:, attempt:, **)
        scan = @scanner.call(image)
        decision = SupplyChainPolicy.new(policy).evaluate(scan.report)
        evidence = persist(attempt, scan, decision)
        reference = { "kind" => "supply_chain_scan", "id" => evidence.id, "digest" => image.digest,
                      "sbom_digest" => evidence.sbom_digest, "report_digest" => evidence.report_digest }
        return Result.pass(evidence_references: [ reference ]) if decision.allowed?

        Result.fail(failure_class: :policy, code: decision.code, message: decision.message, evidence_references: [ reference ])
      rescue ProviderError, Timeout::Error, SystemCallError => e
        Result.fail(failure_class: :infrastructure, code: :scanner_unavailable, message: "supply-chain scanner unavailable: #{e.class}")
      end

      private

      def persist(attempt, scan, decision)
        sbom_json = JSON.generate(scan.sbom)
        report_json = JSON.generate(scan.report)
        evidence = attempt.create_scan_evidence!(
          image_digest: attempt.image_digest, scanner_name: scan.scanner_name, scanner_version: scan.scanner_version,
          database_version: scan.database_version, sbom_format: "cyclonedx-json",
          sbom_digest: digest(sbom_json), report_digest: digest(report_json), finding_summary: decision.summary,
          exemptions: decision.exemptions, decision_evidence: decision.evidence, scanned_at: scan.scanned_at
        )
        evidence.sbom.attach(io: StringIO.new(sbom_json), filename: "sbom-#{attempt.image_digest.delete_prefix('sha256:')}.cdx.json", content_type: "application/vnd.cyclonedx+json")
        evidence.scan_report.attach(io: StringIO.new(report_json), filename: "scan-#{attempt.image_digest.delete_prefix('sha256:')}.json", content_type: "application/json")
        evidence
      end

      def digest(value) = "sha256:#{Digest::SHA256.hexdigest(value)}"
    end
  end
end
