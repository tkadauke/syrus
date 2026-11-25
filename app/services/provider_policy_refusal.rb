class ProviderPolicyRefusal
  OUTCOME = "provider_policy_refusal".freeze
  CLASSIFICATION = "provider_policy_refusal".freeze

  PATTERNS = [
    /\b(?:can't|cannot|won't|will not) (?:help|assist|comply) with (?:that|this) (?:request|task)\b/i,
    /\b(?:request|task) (?:violates|is disallowed by) (?:our|the) (?:safety )?policy\b/i,
    /\brefus(?:e|ed|al)\b.{0,100}\b(?:policy|safety)\b/i,
    /\b(?:policy|safety)\b.{0,100}\brefus(?:e|ed|al)\b/i
  ].freeze

  def self.detect?(text)
    PATTERNS.any? { |pattern| text.to_s.match?(pattern) }
  end
end
