module Syrus
  module ResponseCompression
    CONTENT_TYPES = %w[application/json application/jsonl text/html].freeze
    MINIMUM_BODY_BYTES = 1024

    module_function

    def eligible?(env, _status, headers, body)
      path = env["PATH_INFO"].to_s
      return false if path == "/cable" || path.start_with?("/cable/")
      return false if header_value(headers, Rack::CONTENT_TYPE).to_s.start_with?("text/event-stream")
      return false if header_value(headers, "content-encoding").present?

      body_size(headers, body) >= MINIMUM_BODY_BYTES
    end

    def body_size(headers, body)
      content_length = header_value(headers, Rack::CONTENT_LENGTH)
      return content_length.to_i if content_length.present?

      parts = if body.is_a?(Array)
        body
      elsif body.respond_to?(:to_ary)
        body.to_ary
      end
      return parts.sum(&:bytesize) if parts.is_a?(Array) && parts.all?(String)

      # Unknown-length enumerators may be large response bodies. Do not consume
      # them here: Rack response bodies are not required to be rewindable.
      MINIMUM_BODY_BYTES
    end

    def header_value(headers, name)
      headers.each do |header_name, value|
        return value if header_name.to_s.casecmp?(name)
      end
      nil
    end
    private_class_method :body_size, :header_value
  end
end
