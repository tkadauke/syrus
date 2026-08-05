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

  INCONCLUSIVE_PATTERNS = [
    /failed to refresh available models/i,
    /failed to refresh model metadata/i,
    /stream disconnected before completion/i,
    /failed to decode models response/i,
    /unknown variant [`'"]?max[`'"]?/i,
    /model(?:s)? metadata decode/i,
    /model(?:s)? schema/i
  ].freeze

  MODEL_PATTERNS = [
    /\bmodel(?:\s+name)?\s*[:=]\s*["']?([A-Za-z0-9._:-]+)["']?/i,
    /\bmodel\s+["']([A-Za-z0-9._:-]+)["']/i,
    /\[(?:codex|claude)[^\]]*\]\s+model\s+([A-Za-z0-9._:-]+)\s*:/i,
    /\bmodel\s+([A-Za-z0-9._:-]+)\b.{0,80}\b(?:usage\s+)?limit(?:s)?\b.{0,80}\b(?:exhausted|reached|exceeded)\b/i,
    /\b(?:monthly|weekly|daily|hourly)\s+(?:usage\s+)?limit(?:s)?\s+for\s+model\s+["']?([A-Za-z0-9._:-]+)["']?/i,
    /\b(?:model|token|message|request)\s+(?:usage\s+)?limit(?:s)?\s+(?:for|on)\s+["']?([A-Za-z0-9._:-]+)["']?/i,
    /\b(?:limit|quota)\s+(?:for|on)\s+(?:model\s+)?["']?([A-Za-z0-9._:-]+)["']?\s+(?:exhausted|reached|exceeded)\b/i
  ].freeze

  SUSPICIOUS_MODEL_WORDS = %w[
    a an and are as at available by decode direct error for from in into is job max metadata model models
    of on or response schema the this to unknown usage variant with
  ].freeze

  def self.detect?(text)
    return false if inconclusive?(text)

    LIMIT_PATTERNS.any? { |pattern| text.to_s.match?(pattern) }
  end

  def self.inconclusive?(text)
    INCONCLUSIVE_PATTERNS.any? { |pattern| text.to_s.match?(pattern) }
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
      model = match && match[1].to_s.strip.presence
      return model if model && !suspicious_model?(model)
    end

    nil
  end

  def self.suspicious_model?(model)
    normalized = model.to_s.strip.downcase
    return true if normalized.blank?
    return true if SUSPICIOUS_MODEL_WORDS.include?(normalized)
    return true unless normalized.match?(/\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/)

    false
  end

  def self.detail(provider:, model: nil, message:)
    scope = [ provider.to_s.presence&.capitalize, model.to_s.presence ].compact.join(" ")
    scope = "provider/model" if scope.blank?
    "Syrus halted work for #{scope}: usage limit or quota exhausted. #{message.to_s.strip}"
  end
end
