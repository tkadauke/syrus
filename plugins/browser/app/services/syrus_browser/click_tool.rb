require "mcp"

module SyrusBrowser
  class ClickTool < BrowserTool
    tool_name "browser_click"

    description "Click an element on the current page, targeted by the `ref` from a prior " \
                "browser_snapshot call."

    input_schema(
      type: "object",
      properties: {
        element: { type: "string", description: "Human-readable description of the element, for logging." },
        ref:     { type: "string", description: "Element ref returned by browser_snapshot." }
      },
      required: %w[element ref]
    )

    proxies "browser_click", element: "element", ref: "ref"
  end
end
