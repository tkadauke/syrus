# Detects a provider refusing the model it was asked for, on an account that
# is otherwise healthy.
#
# This is a permanent fault, not a transient one, and that distinction is the
# whole reason it needs its own classification. ProviderCircuitBreaker only
# counts a failure as a signal when it looks transient (overloaded, timed out,
# service unavailable), so a provider that will reject every single request
# until its configuration changes produced no signal at all: no circuit, no
# availability evidence, and therefore no failover to the next routing
# candidate. Every run kept hitting the same wall at full speed.
#
# Observed shape, from a provider that had served the same model for thousands
# of runs and then stopped mid-day with no local change:
#
#   {"type":"error","status":400,"error":{"type":"invalid_request_error",
#    "message":"The 'some-model' model is not supported when using <provider>
#    with a <plan> account."}}
#
# Retrying that is pointless; routing to a different provider is not. Treat it
# the same way an expired credential is treated -- see ProviderAuthFailure,
# which this deliberately mirrors.
class ProviderModelUnsupported
  OUTCOME = "provider_model_unsupported".freeze
  CLASSIFICATION = "provider_model_unsupported".freeze

  PATTERNS = [
    /\bmodel\b.{0,120}\bis not supported\b/i,
    /\bis not supported when using\b/i,
    /\bunsupported[_ ]model\b/i,
    /\bmodel[_ ]not[_ ](?:supported|found)\b/i,
    /\bmodel\b.{0,120}\bdoes not exist or you do not have access\b/i,
    /\bdoes not exist or you do not have access to (?:it|the model)\b/i,
    /\byou do not have access to (?:the )?model\b/i,
    /\bmodel\b.{0,120}\bnot available (?:for|on) (?:your|this) (?:account|plan|subscription)\b/i
  ].freeze

  # Pulls the rejected model out of the message so the evidence row can be
  # scoped to it. Operators need to know *which* model was refused -- that is
  # the difference between "switch models" and "the provider is down".
  MODEL_PATTERNS = [
    /['"`]([A-Za-z0-9][A-Za-z0-9._\-]{1,60})['"`]\s+model\b/i,
    /\bmodel\s+['"`]([A-Za-z0-9][A-Za-z0-9._\-]{1,60})['"`]/i
  ].freeze

  def self.detect?(text)
    PATTERNS.any? { |pattern| text.to_s.match?(pattern) }
  end

  def self.extract_model(text)
    string = text.to_s
    MODEL_PATTERNS.each do |pattern|
      match = string[pattern, 1]
      return match if match.present?
    end
    nil
  end
end
