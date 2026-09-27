module OperatorBriefing
  SEVERITIES = %w[informational fyi decision_required attention_debt].freeze

  DetectorFact = Data.define(:key, :severity, :summary, :evidence) do
    def initialize(key:, severity:, summary:, evidence: [])
      severity = severity.to_s
      raise ArgumentError, "unknown severity=#{severity.inspect}" unless OperatorBriefing::SEVERITIES.include?(severity)

      super(
        key: key.to_s,
        severity: severity,
        summary: summary.to_s,
        evidence: Array(evidence).map { |entry| normalize_evidence(entry) }
      )
    end

    def to_h
      {
        key: key,
        severity: severity,
        summary: summary,
        evidence: evidence
      }
    end

    private

    def normalize_evidence(entry)
      value = entry.respond_to?(:to_h) ? entry.to_h : entry
      value.respond_to?(:stringify_keys) ? value.stringify_keys : value
    end
  end
end
