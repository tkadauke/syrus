require "mcp"
require "json"

module SyrusBrowser
  # Granular browser-control MCP tools for the visual_review agent (and any
  # other agentic step): navigate, click, fill, hover, snapshot, screenshot,
  # wait_for, resize, evaluate, file_upload, drop, drag, close. Deliberately
  # NOT one opaque "run test suite" tool — the agent improvises its own test
  # plan against the running preview.
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
      HoverTool,
      ScreenshotTool,
      WaitForTool,
      ResizeTool,
      EvaluateTool,
      FileUploadTool,
      DropTool,
      DragTool,
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
          input_schema: klass.input_schema_value.to_h,
          capability_descriptor: PermissionProvider.capability_descriptor(DESCRIPTORS.fetch(klass.tool_name))
        }
      end
    end

    DESCRIPTORS = {
      "browser_navigate" => "browser.navigate/open@v1",
      "browser_snapshot" => "browser.observe/read@v1",
      "browser_click" => "browser.interact/action@v1",
      "browser_fill" => "browser.interact/action@v1",
      "browser_hover" => "browser.interact/action@v1",
      "browser_screenshot" => "browser.observe/read@v1",
      "browser_wait_for" => "browser.observe/read@v1",
      "browser_resize" => "browser.observe/read@v1",
      "browser_evaluate" => "browser.execute/evaluate@v1",
      "browser_file_upload" => "browser.upload/file@v1",
      "browser_drop" => "browser.upload/file@v1",
      "browser_drag" => "browser.interact/action@v1",
      "browser_close" => "browser.close/session@v1"
    }.freeze

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
