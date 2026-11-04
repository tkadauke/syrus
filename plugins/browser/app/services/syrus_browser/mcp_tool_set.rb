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
      EmulateTool,
      EvaluateTool,
      FileUploadTool,
      DropTool,
      DragTool,
      CloseTool
    ].freeze

    def self.available_for?(_repository)
      true
    end

    def self.available_for_context?(context)
      run = context.run
      return true unless run&.step&.kind == "visual_review"
      return true unless run.respond_to?(:runtime_sessions)

      sessions = run.runtime_sessions.active
      return true if sessions.for_provider(RuntimeSessionProvider.provider_key).exists?

      # Legacy preview-backed browser reviews do not create RuntimeSession
      # records, so an empty session set keeps the established browser tools.
      sessions.none?
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
      "browser_emulate" => "browser.observe/read@v1",
      "browser_evaluate" => "browser.execute/evaluate@v1",
      "browser_file_upload" => "browser.upload/file@v1",
      "browser_drop" => "browser.upload/file@v1",
      "browser_drag" => "browser.interact/action@v1",
      "browser_close" => "browser.close/session@v1"
    }.freeze

    def handle(tool_name, params, server_context)
      klass = TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
      return BrowserTool.error("Unknown browser tool: #{tool_name.inspect}") unless klass

      context = SessionContext.resolve(server_context)
      response = klass.call(**self.class.symbolize(params), server_context: server_context)
      return response if response.error?

      if tool_name.to_s == "browser_snapshot"
        token = SnapshotFreshness.record(context.session_key)
        response.content << { type: "text", text: "Syrus snapshot token: #{token}. Use this token with snapshot-ref artifact targets." }
      elsif invalidates_snapshot?(tool_name)
        SnapshotFreshness.invalidate(context.session_key)
      end
      response
    rescue StandardError => e
      BrowserTool.error("#{e.class}: #{e.message}")
    end

    private

    def invalidates_snapshot?(tool_name)
      %w[browser_navigate browser_click browser_fill browser_drag browser_drop browser_file_upload browser_evaluate browser_resize browser_emulate].include?(tool_name.to_s)
    end

    def self.symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
