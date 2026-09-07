require "mcp"

module SyrusBrowser
  # Maps to Playwright MCP's "browser_drag": a real mouse-driven drag between two elements
  # targeted by browser_snapshot refs. Covers non-file drag interactions (list reordering,
  # sliders, resizable panels); use browser_drop for native file drag-and-drop onto a drop
  # zone instead — dragging two on-page elements isn't the same operation as dropping a file
  # from outside the page.
  #
  # No `ref` alias here (unlike the other targeted tools): a bare `ref` alias would be
  # ambiguous between start_target and end_target, so callers must use the explicit names.
  class DragTool < BrowserTool
    tool_name "browser_drag"

    description "Drag one element to another via a real mouse-driven drag, targeted by " \
                "start_target/end_target from a prior browser_snapshot call. Use this for " \
                "non-file element-to-element dragging (reordering, resizing); use " \
                "browser_drop for native file drag-and-drop onto a drop zone."

    input_schema(
      type: "object",
      properties: {
        start_element: { type: "string", description: "Human-readable description of the drag source element, for logging." },
        start_target:  { type: "string", description: "Exact target/ref returned by browser_snapshot for the drag source." },
        end_element:   { type: "string", description: "Human-readable description of the drop target element, for logging." },
        end_target:    { type: "string", description: "Exact target/ref returned by browser_snapshot for the drop target." }
      },
      required: %w[start_target end_target]
    )

    proxies "browser_drag",
            start_element: "startElement", start_target: "startTarget",
            end_element: "endElement", end_target: "endTarget"
  end
end
