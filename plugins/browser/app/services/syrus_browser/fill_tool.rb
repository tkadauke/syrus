require "mcp"

module SyrusBrowser
  # Maps to Playwright MCP's "browser_type" (type text into a targeted element).
  class FillTool < BrowserTool
    tool_name "browser_fill"

    description "Type text into a form field, targeted by the `target` from a prior browser_snapshot call."

    input_schema(
      type: "object",
      properties: {
        element: { type: "string", description: "Human-readable description of the element, for logging." },
        target:  { type: "string", description: "Exact target/ref returned by browser_snapshot." },
        text:    { type: "string", description: "Text to type into the field." }
      },
      required: %w[target text]
    )

    argument_aliases target: %i[ref]
    proxies "browser_type", element: "element", target: "target", text: "text"
    requires_input_lease!

    # Text typed into a password or credential-autocomplete field is recorded
    # in the lease audit as a redaction marker and length, never verbatim.
    SENSITIVE_FIELD_PROBE = "(element) => ({ type: (element.type || '').toLowerCase(), " \
                            "autocomplete: (element.getAttribute('autocomplete') || '').toLowerCase() })".freeze
    SENSITIVE_AUTOCOMPLETE = /\b(?:current-password|new-password|one-time-code)\b/

    class << self
      private

      # Fails closed: when the field cannot be inspected, its text is treated
      # as sensitive.
      def sensitive_input?(session, params)
        field = sensitive_field_probe(session, params)
        return true unless field.is_a?(Hash)

        field["type"].to_s == "password" || field["autocomplete"].to_s.match?(SENSITIVE_AUTOCOMPLETE)
      rescue StandardError
        true
      end

      def sensitive_field_probe(session, params)
        response = session.call_tool(name: "browser_evaluate", arguments: {
          "element" => params[:element].presence || "input field", "target" => params[:target],
          "function" => SENSITIVE_FIELD_PROBE
        })
        return nil if response.dig("result", "isError") == true

        text = Array(response.dig("result", "content")).find { |block| block["type"] == "text" }&.dig("text").to_s.strip
        body = text[/(?:\A|\n)### Result\s*\n(?<json>.*?)(?=\n### |\z)/m, :json] || text
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
