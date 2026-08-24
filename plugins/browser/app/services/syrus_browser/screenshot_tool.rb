require "mcp"

module SyrusBrowser
  # Maps to Playwright MCP's "browser_take_screenshot".
  class ScreenshotTool < BrowserTool
    tool_name "browser_screenshot"

    description "Take a screenshot of the current page (or a single element, if `ref` is given). " \
                "Returns image content the agent can inspect directly."

    input_schema(
      type: "object",
      properties: {
        element: { type: "string", description: "Human-readable description of the element to screenshot, if any." },
        ref:     { type: "string", description: "Element ref returned by browser_snapshot, if screenshotting a single element." }
      },
      required: []
    )

    proxies "browser_take_screenshot", element: "element", ref: "ref"
  end
end
