module RuntimeImages
  module Verifications
    class SupplyChainScanner
      Scan = Data.define(:sbom, :report, :scanner_name, :scanner_version, :database_version, :scanned_at)
      OUTPUT_LIMIT = 32.megabytes
      TIMEOUT = 10.minutes

      def initialize(built_images: BuiltImages.new, runner: nil)
        @built_images = built_images
        @runner = runner || method(:run)
      end

      def call(image)
        @built_images.acquire_for_verification(image) do |reference|
          identity = json_command([ "trivy", "version", "--format", "json" ])
          scanner_version = required_identity(identity, "Version")
          vulnerability_database_version = database_version(identity)
          sbom = json_command([ "trivy", "image", "--quiet", "--format", "cyclonedx", reference ])
          report = json_command([ "trivy", "image", "--quiet", "--format", "json", "--scanners", "vuln", "--list-all-pkgs", reference ])
          validate_evidence!(sbom, report)
          Scan.new(sbom: sbom, report: report, scanner_name: "trivy",
                   scanner_version: scanner_version, database_version: vulnerability_database_version,
                   scanned_at: Time.current)
        end
      rescue KeyError => e
        raise ProviderError, "scanner identity is incomplete: #{e.key}"
      end

      private

      def json_command(argv)
        output, status = @runner.call(argv)
        raise ProviderError, "#{argv.first} scanner command failed" unless status.to_i.zero?
        JSON.parse(output)
      rescue JSON::ParserError
        raise ProviderError, "#{argv.first} scanner returned invalid JSON"
      end

      def database_version(identity)
        db = Hash(identity["VulnerabilityDB"] || identity["VulnerabilityDBInfo"])
        value = db["UpdatedAt"] || db["DownloadedAt"] || db["Version"]
        raise ProviderError, "scanner database version is unavailable" if value.blank?

        value
      end

      def required_identity(identity, key)
        value = identity.fetch(key)
        raise ProviderError, "scanner identity is incomplete: #{key}" if value.blank?

        value
      end

      def validate_evidence!(sbom, report)
        raise ProviderError, "scanner SBOM is not CycloneDX JSON" unless sbom.is_a?(Hash) && sbom["bomFormat"] == "CycloneDX"
        raise ProviderError, "scanner vulnerability report has no results collection" unless report.is_a?(Hash) && report["Results"].is_a?(Array)
      end

      def run(argv)
        capture = ProcessRunner.new(env: ENV.slice("PATH", "HOME", "TRIVY_CACHE_DIR").compact,
                                    command: argv, mounts: ProcessRunner.probe_mounts, network: "prepare",
                                    timeout: TIMEOUT, unsetenv_others: true).capture(limit: OUTPUT_LIMIT)
        result = capture.result
        [ capture.stdout.to_s, result.timed_out? ? 124 : (result.success? ? 0 : 1) ]
      end
    end
  end
end
