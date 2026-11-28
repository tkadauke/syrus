module Coworkers
  # Produces the safe, deterministic publication delta used both by permission
  # matching and by operator confirmation. Restricted scanner reports never
  # enter this object; callers supply only their retained safe summaries.
  class EnvironmentPublicationRisk
    Snapshot = Data.define(
      :source_digest, :base_digest, :dependency_digest, :sbom_digest,
      :vulnerabilities, :secret_findings, :network_sources, :network_policy_digest,
      :policy_digest, :policy_result, :image_size
    ) do
      def initialize(source_digest:, base_digest:, dependency_digest:, sbom_digest:, network_policy_digest:,
        policy_digest:, policy_result:, vulnerabilities: {}, network_sources: [], secret_findings: 0,
        image_size: nil)
        super(
          source_digest:, base_digest:, dependency_digest:, sbom_digest:, network_policy_digest:,
          policy_digest:, policy_result:,
          vulnerabilities: vulnerabilities.to_h.stringify_keys.transform_values(&:to_i).sort.to_h.freeze,
          secret_findings: secret_findings.to_i,
          network_sources: Array(network_sources).map(&:to_s).uniq.sort.freeze,
          image_size: image_size&.to_i
        )
      end
    end

    Result = Data.define(:deltas, :summary) do
      def permission_arguments = deltas
    end

    def self.call(candidate:, active: nil) = new(candidate:, active:).call

    def initialize(candidate:, active: nil)
      @candidate = candidate
      @active = active
    end

    def call
      deltas = {
        "source" => change(active&.source_digest, candidate.source_digest),
        "base" => change(active&.base_digest, candidate.base_digest),
        "dependencies" => change(active&.dependency_digest, candidate.dependency_digest),
        "sbom" => change(active&.sbom_digest, candidate.sbom_digest),
        "vulnerabilities" => vulnerability_delta,
        "secrets" => count_delta(active&.secret_findings, candidate.secret_findings),
        "network" => network_delta,
        "policy" => policy_delta
      }.freeze
      Result.new(deltas:, summary: summarize(deltas).freeze)
    end

    private

    attr_reader :candidate, :active

    def change(before, after)
      { "changed" => before != after, "before" => before, "after" => after }.compact.freeze
    end

    def count_delta(before, after)
      before = before.to_i
      after = after.to_i
      { "before" => before, "after" => after, "added" => [ after - before, 0 ].max,
        "removed" => [ before - after, 0 ].max }.freeze
    end

    def vulnerability_delta
      severities = ((active&.vulnerabilities || {}).keys | candidate.vulnerabilities.keys).sort
      severities.to_h do |severity|
        [ severity, count_delta(active&.vulnerabilities&.fetch(severity, 0), candidate.vulnerabilities.fetch(severity, 0)) ]
      end.freeze
    end

    def network_delta
      before = active&.network_sources || []
      after = candidate.network_sources
      {
        "added" => after - before, "removed" => before - after,
        "policy" => change(active&.network_policy_digest, candidate.network_policy_digest)
      }.freeze
    end

    def policy_delta
      change(active&.policy_digest, candidate.policy_digest).merge(
        "result" => candidate.policy_result.to_s
      ).freeze
    end

    def summarize(deltas)
      added_vulnerabilities = deltas.fetch("vulnerabilities").sum { |_severity, value| value.fetch("added") }
      changed = %w[source base dependencies sbom].select { |key| deltas.fetch(key).fetch("changed") }
      {
        "changed_material" => changed,
        "vulnerabilities_added" => added_vulnerabilities,
        "secret_findings" => candidate.secret_findings,
        "network_sources_added" => deltas.dig("network", "added").size,
        "policy_result" => candidate.policy_result.to_s
      }
    end
  end
end
