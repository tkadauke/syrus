require "mcp"

module SyrusBrowser
  # Maps to Playwright MCP's "browser_type" (type text into a targeted element).
  class FillTool < BrowserTool
    tool_name "browser_fill"

    description "Type text into a form field, targeted by the `ref` from a prior browser_snapshot call."

    input_schema(
      type: "object",
      properties: {
        element: { type: "string", description: "Human-readable description of the element, for logging." },
        ref:     { type: "string", description: "Element ref returned by browser_snapshot." },
        text:    { type: "string", description: "Text to type into the field." }
      },
      required: %w[element ref text]
    )

    proxies "browser_type", element: "element", ref: "ref", text: "text"
  end
end
