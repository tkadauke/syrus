require "mcp"

module SyrusBrowser
  class HoverTool < BrowserTool
    tool_name "browser_hover"

    description "Hover the mouse over an element on the current page, targeted by the `target` from a prior " \
                "browser_snapshot call. Use this for :hover-triggered UI (tooltips, hover popups/cards, " \
                "hover-revealed controls) that browser_click cannot exercise."

    input_schema(
      type: "object",
      properties: {
        element: { type: "string", description: "Human-readable description of the element, for logging." },
        target:  { type: "string", description: "Exact target/ref returned by browser_snapshot." }
      },
      required: %w[target]
    )

    argument_aliases target: %i[ref]
    proxies "browser_hover", element: "element", target: "target"
  end
end
