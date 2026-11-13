module Observability
  module EventPayloadSanitizer
    REDACTED = "[FILTERED]".freeze
    REDACTED_QUERY = "?[FILTERED]".freeze

    module_function

    def sanitize(payload)
      filtered = ActiveSupport::ParameterFilter
        .new(Rails.application.config.filter_parameters)
        .filter(payload)
      sanitized = redact_text_values(filtered)

      scrub_locations!(sanitized)
    end

    def redact_text_values(value)
      case value
      when String
        ToolPayloadRedactor.redact_text(value)
      when Array
        value.map { |entry| redact_text_values(entry) }
      when Hash
        value.transform_values { |entry| redact_text_values(entry) }
      else
        value
      end
    end

    def scrub_locations!(payload)
      payload[:url] = scrub_location(payload[:url]) if payload.key?(:url)
      payload[:path] = scrub_location(payload[:path]) if payload.key?(:path)
      Array(payload[:recent_api_requests]).each do |request|
        next unless request.is_a?(Hash)

        key = request.key?("path") ? "path" : :path
        request[key] = scrub_location(request[key]) if request.key?(key)
      end
      payload
    end

    def scrub_location(value)
      location = value.to_s
        .sub(%r{(/api/v1/app/auth/passwords/)[^/?#]+}i, "\\1#{REDACTED}")
        .sub(%r{(/passwords/)[^/?#]+(/edit\b)}i, "\\1#{REDACTED}\\2")
        .sub(%r{(/chats/shared/)[^/?#]+}i, "\\1#{REDACTED}")
      query_index = location.index("?")
      query_index ? "#{location[0...query_index]}#{REDACTED_QUERY}" : location
    end
  end
end
