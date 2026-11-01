require "digest"
require "json"
require "time"

module Permissions
  class CoworkerCutoverDeploymentGuard
    MAX_ARTIFACT_AGE = 7.days
    MIN_PARITY_SAMPLES = 100
    MAX_PARITY_MISMATCH_RATE = 0.01
    REQUIRED_SUITES = %w[evaluator dispatch].freeze

    class VerificationError < StandardError; end

    def initialize(path:, target_sha:, previous_sha:, now: Time.current)
      @path = path
      @target_sha = target_sha
      @previous_sha = previous_sha
      @now = now
    end

    def verify!
      artifact = JSON.parse(File.read(path))
      evidence = artifact.fetch("evidence")
      failures = []

      failures << "artifact digest does not match its evidence" unless secure_digest(evidence) == artifact["sha256"]
      failures << "artifact targets #{evidence['target_sha'].inspect}, not #{target_sha}" unless sha_matches?(evidence["target_sha"], target_sha)
      failures << "artifact rollback SHA does not match the deployed release" unless sha_matches?(evidence.dig("rollback", "image_sha"), previous_sha)
      failures << "capability descriptors are incomplete" unless passed_check?(evidence.fetch("descriptors", {}), "complete")
      failures << "schema compatibility is unverified" unless passed_check?(evidence.fetch("schema", {}), "compatible")
      failures.concat(parity_failures(evidence.fetch("parity", {})))
      failures.concat(report_failures(evidence.fetch("cutover_report", {})))
      failures.concat(suite_failures(evidence.fetch("suites", {})))
      failures.concat(rollback_failures(evidence.fetch("rollback", {})))
      failures << "artifact is older than #{MAX_ARTIFACT_AGE.inspect}" unless fresh?(evidence["verified_at"])

      raise VerificationError, failures.join("; ") if failures.any?
      true
    rescue Errno::ENOENT, JSON::ParserError, KeyError => error
      raise VerificationError, "invalid cutover artifact: #{error.message}"
    end

    def self.digest(evidence)
      Digest::SHA256.hexdigest(JSON.generate(canonical(evidence)))
    end

    def self.canonical(value)
      case value
      when Hash then value.keys.sort.index_with { |key| canonical(value.fetch(key)) }
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    private

    attr_reader :path, :target_sha, :previous_sha, :now

    def secure_digest(evidence)
      self.class.digest(evidence)
    end

    def sha_matches?(recorded, actual)
      recorded.present? && actual.present? && (recorded.start_with?(actual) || actual.start_with?(recorded))
    end

    def parity_failures(parity)
      failures = []
      samples = parity["samples"].to_i
      mismatch_rate = samples.positive? ? parity["mismatches"].to_i.fdiv(samples) : Float::INFINITY
      failures << "permission parity needs at least #{MIN_PARITY_SAMPLES} samples" if samples < MIN_PARITY_SAMPLES
      failures << "permission parity mismatch threshold was exceeded" if mismatch_rate > MAX_PARITY_MISMATCH_RATE
      failures << "permission evaluation failures were observed" unless parity["evaluation_failures"].to_i.zero?
      failures
    end

    def passed_check?(check, result)
      check[result] == true && check["command"].present?
    end

    def report_failures(report)
      return [] if report["ready"] == true && report["acknowledged_by"].present? && timestamp?(report["acknowledged_at"])
      [ "cutover report is not ready and explicitly acknowledged" ]
    end

    def suite_failures(suites)
      REQUIRED_SUITES.filter_map do |suite|
        "#{suite} suite did not pass" unless suites.dig(suite, "passed") == true && suites.dig(suite, "command").present?
      end
    end

    def rollback_failures(rollback)
      return [] if rollback["succeeded"] == true && rollback["command"].present? && timestamp?(rollback["verified_at"])
      [ "deployment rollback is not verified" ]
    end

    def fresh?(value)
      timestamp = Time.iso8601(value.to_s)
      timestamp <= now && timestamp >= now - MAX_ARTIFACT_AGE
    rescue ArgumentError
      false
    end

    def timestamp?(value)
      Time.iso8601(value.to_s)
      true
    rescue ArgumentError
      false
    end
  end
end
