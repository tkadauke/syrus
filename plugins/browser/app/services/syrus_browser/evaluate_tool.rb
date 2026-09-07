require "mcp"

module SyrusBrowser
  # Maps to Playwright MCP's "browser_evaluate": runs a JS function in the page (or, when
  # `target` is given, with the targeted element passed in) and returns its result. This is
  # the tool that lets the reviewer construct a synthetic `File`/`DataTransfer` and dispatch
  # `dragenter`/`dragover`/`drop` events on a real drop-zone element to exercise native file
  # drag-and-drop end to end, since no browser automation tool can synthesize an actual
  # OS-level file drag.
  #
  # Arbitrary JS execution is more powerful than the other proxied tools, but it doesn't
  # expand what a workflow agent can already do: the review step already has unrestricted
  # shell access to the same sandboxed workspace (see Prompts::VisualReview), so an agent
  # willing to exfiltrate data via evaluated `fetch`/XHR could already do so directly via
  # shell. LoopbackGuard restricts browser_navigate's top-level target, not this tool's
  # in-page network calls, because the actual security boundary here is the workflow
  # sandbox/network egress policy, not the browser tool surface.
  class EvaluateTool < BrowserTool
    tool_name "browser_evaluate"

    description "Evaluate a JavaScript function in the page, optionally scoped to an element " \
                "targeted by the `target` from a prior browser_snapshot call. Use this to " \
                "construct a synthetic DataTransfer and dispatch dragenter/dragover/drop " \
                "events for testing native file drag-and-drop, mirroring how the codebase's " \
                "own RTL tests exercise the same drop handlers."

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
