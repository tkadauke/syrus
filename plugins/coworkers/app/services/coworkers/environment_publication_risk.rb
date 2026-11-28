require "digest"

module Coworkers
  # Produces the canonical, non-secret evidence delta used to authorize one
  # candidate publication. Restricted scanner reports stay behind their normal
  # evidence boundary; permission matching receives stable digests and counts.
  class EnvironmentPublicationRisk
    Result = Data.define(:deltas, :summary)

    def initialize(environment, revision)
      @environment = environment
      @revision = revision
    end

    def call
      Result.new(deltas: deltas.freeze, summary: summary.freeze)
    end

    private

    attr_reader :environment, :revision

    def candidate_attempt = @candidate_attempt ||= latest_attempt(revision)
    def active_attempt = @active_attempt ||= latest_attempt(environment.active_revision)
    def candidate_scan = candidate_attempt&.scan_evidence
    def active_scan = active_attempt&.scan_evidence
    def candidate_policy = candidate_attempt&.policy_evidence
    def active_policy = active_attempt&.policy_evidence
    def build_evidence = revision.build_request&.evidences&.last
    def active_build_evidence = environment.active_revision&.build_request&.evidences&.last

    def latest_attempt(item)
      item&.runtime_image&.runtime_image_verification_attempts&.where(image_digest: item.runtime_image.digest)&.order(number: :desc)&.first
    end

    def deltas
      @deltas ||= {
        "source" => change(revision.source_digest, environment.active_revision&.source_digest),
        "base" => change(revision.base_release&.digest, environment.active_revision&.base_release&.digest),
        "dependencies" => count_delta(scan_summary(candidate_scan)["packages"], scan_summary(active_scan)["packages"]),
        "sbom" => change(candidate_scan&.sbom_digest, active_scan&.sbom_digest),
        "vulnerabilities" => vulnerability_delta,
        "secrets" => count_delta(policy_codes(candidate_policy)["secret_detected"], policy_codes(active_policy)["secret_detected"]),
        "network" => network_delta,
        "policy" => change(candidate_attempt&.policy_digest, active_attempt&.policy_digest)
      }.freeze
    end

    def change(current, previous)
      { "previous" => previous, "current" => current, "changed" => current != previous }.compact
    end

    def count_delta(current, previous)
      current = current.to_i
      previous = previous.to_i
      { "previous" => previous, "current" => current, "delta" => current - previous }
    end

    def vulnerability_delta
      current = Hash(scan_summary(candidate_scan)["blocked_vulnerability_severities"]).transform_keys { |key| key.to_s.downcase }.sort.to_h
      previous = Hash(scan_summary(active_scan)["blocked_vulnerability_severities"]).transform_keys { |key| key.to_s.downcase }.sort.to_h
      { "previous" => previous, "current" => current,
        "delta" => (current.keys | previous.keys).sort.to_h { |key| [ key, current[key].to_i - previous[key].to_i ] } }
    end

    def network_delta
      current = Array(build_evidence&.destinations).map { |item| item.to_h.slice("source_class", "host", "count") }
      previous = Array(active_build_evidence&.destinations).map { |item| item.to_h.slice("source_class", "host", "count") }
      { "previous_digest" => digest(previous), "current_digest" => digest(current),
        "destination_count" => current.sum { |item| item["count"].to_i }, "changed" => current != previous }
    end

    def scan_summary(evidence) = evidence&.finding_summary.to_h
    def policy_summary(evidence) = evidence&.safe_summary.to_h
    def policy_codes(evidence) = Hash(policy_summary(evidence)["codes"])
    def digest(value) = "sha256:#{Digest::SHA256.hexdigest(JSON.generate(value))}"

    def summary
      changed = deltas.select do |_key, value|
        value["changed"] || value["delta"].is_a?(Numeric) && !value["delta"].zero? ||
          value["delta"].is_a?(Hash) && value["delta"].values.any? { |count| !count.to_i.zero? }
      end
      vulnerability_increase = Hash(deltas.dig("vulnerabilities", "delta")).select { |_severity, count| count.positive? }
      {
        "headline" => changed.empty? ? "No material publication risk changes" : "#{changed.size} material publication risk area(s) changed",
        "changed_areas" => changed.keys, "vulnerability_increases" => vulnerability_increase,
        "secret_count" => deltas.dig("secrets", "current"),
        "network_destination_count" => deltas.dig("network", "destination_count")
      }
    end
  end
end
