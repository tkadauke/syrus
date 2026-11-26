module RuntimeImages
  module Verifications
    class SupplyChainPolicy
      Decision = Data.define(:allowed, :summary, :exemptions, :evidence, :code, :message) do
        def allowed? = allowed
      end

      def initialize(policy, now: Time.current)
        @policy = Hash(policy).deep_stringify_keys
        @now = now
      end

      def evaluate(report)
        results = Array(report["Results"])
        vulnerabilities = results.flat_map { |result| Array(result["Vulnerabilities"]) }
        packages = results.flat_map { |result| Array(result["Packages"]) }
        active_exemptions = Array(@policy["exemptions"]).filter_map { |entry| active_exemption(entry) }
        blocked_severities = Array(@policy.dig("vulnerabilities", "blocked_severities")).map(&:upcase)
        prohibited = Array(@policy["prohibited_packages"]).map(&:to_s)
        blocked_vulnerabilities = vulnerabilities.select do |finding|
          blocked_severities.include?(finding["Severity"].to_s.upcase) && !exempted?(active_exemptions, "vulnerability", finding["VulnerabilityID"])
        end
        blocked_packages = packages.select do |package|
          prohibited.include?(package["Name"].to_s) && !exempted?(active_exemptions, "package", package["Name"])
        end
        summary = severity_counts(vulnerabilities).merge(
          "packages" => packages.size, "blocked_vulnerabilities" => blocked_vulnerabilities.size,
          "prohibited_packages" => blocked_packages.size, "layers_scanned" => layer_count(vulnerabilities, packages)
        )
        evidence = {
          "blocked_vulnerability_ids" => blocked_vulnerabilities.map { |finding| finding["VulnerabilityID"] }.uniq.sort,
          "prohibited_package_names" => blocked_packages.map { |package| package["Name"] }.uniq.sort
        }
        if blocked_vulnerabilities.empty? && blocked_packages.empty?
          return Decision.new(allowed: true, summary: summary, exemptions: active_exemptions, evidence: evidence, code: nil, message: nil)
        end

        code = blocked_packages.any? ? "prohibited_package" : "blocked_vulnerability"
        Decision.new(allowed: false, summary: summary, exemptions: active_exemptions, evidence: evidence,
                     code: code, message: "supply-chain policy blocked #{blocked_vulnerabilities.size} vulnerability finding(s) and #{blocked_packages.size} prohibited package(s)")
      end

      private

      def active_exemption(entry)
        exemption = Hash(entry).stringify_keys
        expires_at = Time.iso8601(exemption.fetch("expires_at"))
        return if expires_at <= @now
        return unless exemption["reason"].present? && %w[vulnerability package].include?(exemption["kind"])

        exemption.slice("kind", "id", "reason", "expires_at")
      rescue KeyError, ArgumentError
        nil
      end

      def exempted?(exemptions, kind, id)
        exemptions.any? { |entry| entry["kind"] == kind && entry["id"] == id.to_s }
      end

      def severity_counts(findings)
        findings.each_with_object(Hash.new(0)) { |finding, counts| counts[finding["Severity"].to_s.downcase] += 1 }.sort.to_h
      end

      def layer_count(vulnerabilities, packages)
        (vulnerabilities + packages).filter_map { |entry| entry.dig("Layer", "Digest") }.uniq.size
      end
    end
  end
end
