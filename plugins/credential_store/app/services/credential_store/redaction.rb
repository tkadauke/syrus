module CredentialStore
  module Redaction
    REDACTION = "[credential redacted]".freeze
    UNSAFE_PROBE_PATTERNS = [
      /-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/m,
      /(?i)(authorization:\s*bearer\s+)[^\s"'\\]+/,
      /(?i)(token|password|passphrase|secret|credential)(\s*[:=]\s*)[^\s"'\\]+/
    ].freeze

    module_function

    def scrub(value, credentials: [], extra_secrets: [])
      scrub_string(value.to_s, secrets_for(credentials: credentials, extra_secrets: extra_secrets))
    end

    def scrub_object(value, credentials: [], extra_secrets: [])
      secrets = secrets_for(credentials: credentials, extra_secrets: extra_secrets)
      scrub_value(value, secrets)
    end

    def secrets_for(credentials:, extra_secrets:)
      Array(credentials).filter_map { |credential| credential.respond_to?(:payload) ? credential.payload : credential }
        .concat(Array(extra_secrets))
        .filter_map { |secret| secret.to_s.presence }
        .select { |secret| secret.bytesize >= 4 }
        .uniq
    end
    private_class_method :secrets_for

    def scrub_value(value, secrets)
      if mcp_response_like?(value)
        return scrub_response(value, secrets)
      end

      case value
      when Hash
        value.transform_values { |nested| scrub_value(nested, secrets) }
      when Array
        value.map { |nested| scrub_value(nested, secrets) }
      when String
        scrub_string(value, secrets)
      else
        value
      end
    end
    private_class_method :scrub_value

    def mcp_response_like?(value)
      value.respond_to?(:content) && value.respond_to?(:error?) && value.class.name == "MCP::Tool::Response"
    end
    private_class_method :mcp_response_like?

    def scrub_response(response, secrets)
      kwargs = { error: response.error? }
      kwargs[:structured_content] = scrub_value(response.structured_content, secrets) if response.respond_to?(:structured_content)
      kwargs[:meta] = scrub_value(response.meta, secrets) if response.respond_to?(:meta)

      if response.respond_to?(:content_provided?) && !response.content_provided?
        response.class.new(**kwargs)
      else
        response.class.new(scrub_value(response.content, secrets), **kwargs)
      end
    end
    private_class_method :scrub_response

    def scrub_string(text, secrets)
      scrubbed = text.dup
      secrets.each { |secret| scrubbed.gsub!(secret, REDACTION) }
      UNSAFE_PROBE_PATTERNS.each { |pattern| scrubbed.gsub!(pattern, replacement_for(pattern)) }
      scrubbed
    end
    private_class_method :scrub_string

    def replacement_for(pattern)
      pattern.names.any? ? "\\1#{REDACTION}" : REDACTION
    end
    private_class_method :replacement_for
  end
end
