module PendingActions
  class LocalToolCall < Base
    action_key "local_tool_call"
    requires_chat_session!

    ALLOWED_TOOLS = %w[run_command write_file].freeze
    PRESENTATION_LABELS = {
      "run_command" => "Run local command",
      "write_file" => "Write local file"
    }.freeze
    DETAIL_BUILDERS = {
      "run_command" => ->(arguments) { arguments["command"].to_s },
      "write_file" => lambda { |arguments|
        path = arguments["path"].to_s
        bytes = arguments["content"].to_s.bytesize
        "#{path} (#{bytes} bytes)"
      }
    }.freeze

    def execute
      raise ArgumentError, "local_tool_call is only available in Local Mode" unless chat_session.local?

      response = Mcp::Tools::LocalToolDispatch.execute_now(
        payload.fetch("tool_name"),
        payload.fetch("arguments"),
        chat_session: chat_session
      )
      raise ArgumentError, response.content.first[:text].to_s if response.error?

      nil
    end

    def execution_label
      "Running Local Mode #{tool_label}..."
    end

    def validate_payload(errors)
      errors.add(:payload, "tool_name is required") unless payload["tool_name"].present?
      errors.add(:payload, "tool_name is not confirmable") if payload["tool_name"].present? && !ALLOWED_TOOLS.include?(payload["tool_name"].to_s)
      errors.add(:payload, "arguments must be an object") unless payload["arguments"].is_a?(Hash)
    end

    def action_detail
      "#{payload["tool_name"]}: #{detail_text}"
    end

    def presentation_label
      PRESENTATION_LABELS.fetch(payload["tool_name"].to_s, "Run Local Mode tool")
    end

    def presentation_detail
      detail_text.presence
    end

    private

    def arguments
      payload["arguments"].to_h
    end

    def tool_label
      payload["tool_name"].to_s.humanize(capitalize: false)
    end

    def detail_text
      DETAIL_BUILDERS[payload["tool_name"].to_s]&.call(arguments)
    end
  end
end
