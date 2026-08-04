class ProviderUsageLimit
  OUTCOME = "provider_usage_limit".freeze
  CLASSIFICATION = "provider_usage_limit".freeze

  LIMIT_PATTERNS = [
    /\byou(?:'|’)re\s+out\s+of\s+extra\s+usage\b/i,
    /\busage(?:\s|-)?limit(?:s)?\b/i,
    /\binsufficient[_ -]?quota\b/i,
    /\b(?:monthly|weekly|daily|hourly)\s+(?:usage\s+)?limit(?:s)?\b/i,
    /\b(?:quota|credits?|billing|balance)\s+(?:is\s+)?(?:exhausted|depleted|expired|insufficient|exceeded|used up|empty)\b/i,
    /\b(?:exhausted|depleted|used up|exceeded)\s+(?:your\s+)?(?:quota|credits?|balance|usage)\b/i,
    /\bout of (?:extra )?usage\b/i,
    /\b(?:model|token|message|request)\s+(?:usage\s+)?limit(?:s)?\s+(?:exhausted|reached|exceeded)\b/i,
    /\b(?:model|token|message|request)?\s*(?:usage\s+)?limit(?:s)?\s+for\s+(?:model\s+)?[A-Za-z0-9._:-]+\s+(?:has\s+been\s+)?(?:exhausted|reached|exceeded)\b/i,
    /\b(?:limit|quota)\s+(?:for|on)\s+(?:model\s+)?[A-Za-z0-9._:-]+\s+(?:exhausted|reached|exceeded)\b/i,
    /\b(?:upgrade|add credits|check billing|billing plan)\b.*\b(?:usage|quota|credits?|limit)\b/i
  ].freeze

  MODEL_PATTERNS = [
    /\bmodel(?:\s+name)?\s*[:=]\s*["']?([A-Za-z0-9._:-]+)["']?/i,
    /\bmodel\s+["']([A-Za-z0-9._:-]+)["']/i,
    /\bmodel\s+([A-Za-z0-9._:-]+)\b/i,
    /\b(?:limit|quota)\s+(?:for|on)\s+(?:model\s+)?["']?([A-Za-z0-9._:-]+)["']?/i
  ].freeze

  def self.detect?(text)
    LIMIT_PATTERNS.any? { |pattern| text.to_s.match?(pattern) }
  end

  def self.run_can_exhaust_provider?(run)
    return true if run.agent_outcome.to_s == OUTCOME
    return true if run.step.nil?

    run.step&.agentic? == true
  end

  def self.extract_model(text, fallback: nil)
    explicit = fallback.to_s.strip.presence
    return explicit if explicit

    MODEL_PATTERNS.each do |pattern|
      match = text.to_s.match(pattern)
      return match[1] if match && match[1].present?
    end

    nil
  end

  def self.detail(provider:, model: nil, message:)
    scope = [ provider.to_s.presence&.capitalize, model.to_s.presence ].compact.join(" ")
    scope = "provider/model" if scope.blank?
    "Syrus halted work for #{scope}: usage limit or quota exhausted. #{message.to_s.strip}"
  end
end
