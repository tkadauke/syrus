require "mcp"
require "json"

module SyrusBrowser
  # Real Playwright text input into whatever element has focus, for a Runtime
  # panel paste that has no snapshot target. Uses `page.keyboard.insertText`
  # through `browser_run_code_unsafe` (native input, no synthetic DOM event).
  # Internal to runtime_input: not part of McpToolSet.
  class InsertTextTool < BrowserTool
    tool_name "browser_insert_text"

    description "Insert text into the focused element through Playwright's keyboard (runtime_input only)."

    input_schema(
      type: "object",
      properties: { text: { type: "string" } },
      required: %w[text]
    )

    proxies "browser_run_code_unsafe"
    requires_input_lease!

    SCRIPT = <<~JS.freeze
      async (page) => {
        await page.keyboard.insertText(%<text>s);
        return { delivered: true };
      }
    JS

    class << self
      private

      def upstream_arguments(params)
        { "code" => format(SCRIPT, text: JSON.generate(params[:text].to_s)) }
      end
    end
  end
end
