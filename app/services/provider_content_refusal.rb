# Detects a provider declining to work on this particular content -- a
# safety-filter refusal -- as opposed to a provider fault.
#
# Observed shape, from a reviewer working on container-build isolation code:
#
#   This content was flagged for possible cybersecurity risk. If this seems
#   wrong, try rephrasing your request. ...
#
# It arrived as a failed turn, which reads as transient, so the step was
# resumed in the same provider session four times and refused identically
# each time. The refusal is about the content and that provider, not the
# provider's health: the same provider keeps serving other Jobs, so this
# must not mark it unavailable (contrast ProviderModelUnsupported). The cure
# is to run the step again on a different provider, in a fresh session.
class ProviderContentRefusal
  OUTCOME = "provider_content_refused".freeze
  CLASSIFICATION = "provider_content_refused".freeze

  PATTERNS = [
    /\bcontent was flagged for possible\b/i,
    /\bflagged for possible (?:cybersecurity|security) risk\b/i,
    /\bappears to violate (?:our|the) usage polic(?:y|ies)\b/i,
    /\bunable to respond to this request\b.{0,120}\busage polic(?:y|ies)\b/i
  ].freeze

  def self.detect?(text)
    PATTERNS.any? { |pattern| text.to_s.match?(pattern) }
  end
end
