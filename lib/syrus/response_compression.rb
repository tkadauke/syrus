module Syrus
  module ResponseCompression
    CONTENT_TYPES = %w[application/json application/jsonl text/html].freeze
    MINIMUM_BODY_SIZE = 1_024

    module_function

    def compress?(env, _status, headers, body)
      return false if action_cable_request?(env)

      content_length = headers[Rack::CONTENT_LENGTH]
      return content_length.to_i >= MINIMUM_BODY_SIZE if content_length.present?
      return body.sum(&:bytesize) >= MINIMUM_BODY_SIZE if body.is_a?(Array)

      # Streaming bodies cannot be measured without consuming them. Their
      # content type still has to pass Rack::Deflater's narrow allowlist.
      true
    end

    def action_cable_request?(env)
      env["PATH_INFO"] == "/cable" || env["HTTP_UPGRADE"].to_s.casecmp?("websocket")
    end
  end
end
