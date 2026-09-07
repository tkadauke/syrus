require "mcp"

module SyrusBrowser
  # Maps to Playwright MCP's "browser_evaluate": runs a JS function in the page (or, when
  # `target` is given, with the targeted element passed in) and returns its result. General-
  # purpose fallback for page inspection/assertions that no other proxied tool covers,
  # including drag-and-drop edge cases browser_drop's paths/data model doesn't reach
  # (inspecting intermediate drag states, a custom DataTransfer configuration). Prefer
  # browser_drop for the common case of dropping a file onto a drop zone — it synthesizes a
  # real drag/drop via Playwright itself rather than a hand-rolled DataTransfer approximation.
  #
  # Arbitrary JS execution is more powerful than the other proxied tools, but it doesn't
  # meaningfully expand what a workflow agent can already do: the review step already has
  # unrestricted shell access to the same sandboxed workspace (see Prompts::VisualReview), so
  # an agent willing to exfiltrate data via evaluated `fetch`/XHR could already do so directly
  # via shell — there is no separate network egress policy this tool would be bypassing.
  # LoopbackGuard only restricts browser_navigate's top-level navigation target; it makes no
  # claim about in-page network calls, evaluated or otherwise.
  class EvaluateTool < BrowserTool
    tool_name "browser_evaluate"

    description "Evaluate a JavaScript function in the page, optionally scoped to an element " \
                "targeted by the `target` from a prior browser_snapshot call. General-purpose " \
                "fallback for page inspection or drag-and-drop edge cases browser_drop doesn't " \
                "cover; prefer browser_drop for dropping a file onto a drop zone."

    input_schema(
      type: "object",
      properties: {
        element:  { type: "string", description: "Human-readable description of the element, for logging." },
        target:   { type: "string", description: "Exact target/ref returned by browser_snapshot, if scoping the function to an element." },
        function: { type: "string", description: "() => { /* code */ } or (element) => { /* code */ } when target is provided." }
      },
      required: %w[function]
    )

    argument_aliases target: %i[ref]
    proxies "browser_evaluate", element: "element", target: "target", function: "function"
  end
end
