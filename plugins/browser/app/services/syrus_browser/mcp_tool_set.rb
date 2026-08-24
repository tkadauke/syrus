require "mcp"
require "json"

module SyrusBrowser
  # Granular browser-control MCP tools for the visual_review agent (and any
  # other agentic step): navigate, click, fill, snapshot, screenshot,
  # wait_for, close. Deliberately NOT one opaque "run test suite" tool — the
  # agent improvises its own test plan against the running preview.
  #
  # Each concrete tool (see BrowserTool and its subclasses in this
  # directory) is its own MCP::Tool class; this set just aggregates them and
  # dispatches by name instead of a growing case statement.
  class McpToolSet
    TOOL_CLASSES = [
      NavigateTool,
      SnapshotTool,
      ClickTool,
      FillTool,
      ScreenshotTool,
      WaitForTool,
      CloseTool
    ].freeze

    def self.available_for?(_repository)
      true
    end

    def self.tool_definitions
      TOOL_CLASSES.map do |klass|
        {
          name: klass.tool_name,
          description: klass.description_value,
          input_schema: klass.input_schema_value.to_h
        }
      end
    end

    def handle(tool_name, params, server_context)
      klass = TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
      return BrowserTool.error("Unknown browser tool: #{tool_name.inspect}") unless klass

      klass.call(**self.class.symbolize(params), server_context: server_context)
    rescue StandardError => e
      BrowserTool.error("#{e.class}: #{e.message}")
    end

    def self.symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
