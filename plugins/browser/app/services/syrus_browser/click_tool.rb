require "mcp"

module SyrusBrowser
  class ClickTool < BrowserTool
    tool_name "browser_click"

    description "Click an element on the current page, targeted by the `target` from a prior " \
                "browser_snapshot call."

    input_schema(
      type: "object",
      properties: {
        element: { type: "string", description: "Human-readable description of the element, for logging." },
        target:  { type: "string", description: "Exact target/ref returned by browser_snapshot." }
      },
      required: %w[target]
    )

    argument_aliases target: %i[ref]
    proxies "browser_click", element: "element", target: "target"
  end
end
