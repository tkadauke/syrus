# Shapes a Runtime Session input event for audit evidence (run JobLogs, the
# control channel broadcast). The provider always delivers the original event;
# only the recorded copy passes through here.
#
# Typed text is recorded verbatim only when nothing suggests it is a secret.
# It is replaced by a redaction marker plus its length when:
#
# - the caller says the target is sensitive (a browser password field, a
#   terminal password prompt), or the event itself carries a password
#   input_type or a credential autocomplete hint;
# - the element description names a credential field; or
# - the text matches an existing secret pattern (ToolPayloadRedactor or
#   CommandRedactor would change it).
#
# Every other value still goes through ToolPayloadRedactor, so secret-named
# keys and inline secrets elsewhere in the event are redacted too.
class RuntimeInputRedaction
  REDACTED = ToolPayloadRedactor::REDACTED
  TEXT_KEYS = %w[text value data].freeze
  SENSITIVE_AUTOCOMPLETE = /\b(?:current-password|new-password|one-time-code)\b/i
  SENSITIVE_INPUT_TYPE = /\Apassword\z/i
  SENSITIVE_ELEMENT = /pass(?:word|phrase|code)|\bpin\b|one[-\s]?time|\botp\b|\bmfa\b|2fa|verification code|secret|token|api[-\s_]?key|credential/i
  HINT_KEYS = %w[_sensitive sensitive].freeze

  def self.call(event, sensitive: false) = new(event, sensitive: sensitive).call

  def initialize(event, sensitive: false)
    @event = event.respond_to?(:to_unsafe_h) ? event.to_unsafe_h : event.to_h
    @event = @event.deep_stringify_keys
    @sensitive = sensitive
  end

  def call
    sensitive = sensitive_target?
    texts, rest = @event.except(*HINT_KEYS).partition { |key, value| TEXT_KEYS.include?(key) && value.is_a?(String) }.map(&:to_h)
    shaped = ToolPayloadRedactor.redact(rest)
    texts.each do |key, value|
      if sensitive || secret_text?(value)
        shaped[key] = REDACTED
        shaped["#{key}_length"] = value.length
      else
        shaped[key] = value
      end
    end
    shaped
  end

  private

  def sensitive_target?
    return true if @sensitive
    return true if ActiveModel::Type::Boolean.new.cast(@event["_sensitive"]) || ActiveModel::Type::Boolean.new.cast(@event["sensitive"])
    return true if @event["input_type"].to_s.match?(SENSITIVE_INPUT_TYPE)
    return true if @event["autocomplete"].to_s.match?(SENSITIVE_AUTOCOMPLETE)

    @event["element"].is_a?(String) && @event["element"].match?(SENSITIVE_ELEMENT)
  end

  def secret_text?(text)
    ToolPayloadRedactor.redact_text(text) != text || CommandRedactor.redact(text) != text
  end
end
