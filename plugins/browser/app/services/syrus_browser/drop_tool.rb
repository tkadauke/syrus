require "mcp"

module SyrusBrowser
  # Maps to Playwright MCP's "browser_drop": drops files or MIME-typed data onto an element
  # "as if dragged from outside the page" via Playwright's own drag/drop synthesis. This is
  # the preferred tool for native file drag-and-drop onto a drop zone found via
  # browser_snapshot — it drops real files backed by real bytes on disk, more faithful than
  # hand-constructing a `File`/`DataTransfer` via browser_evaluate. Reach for browser_evaluate
  # instead only when a scenario needs something browser_drop's paths/data model doesn't
  # cover: inspecting intermediate drag states, a custom DataTransfer configuration (e.g.
  # effectAllowed/dropEffect), or asserting on non-drag page behavior.
  class DropTool < BrowserTool
    tool_name "browser_drop"

    description "Drop files or MIME-typed data onto an element, as if dragged from outside " \
                "the page, targeted by the `target` from a prior browser_snapshot call. This " \
                "is the preferred tool for native file drag-and-drop onto a drop zone — prefer " \
                "it over hand-rolling a DataTransfer via browser_evaluate. At least one of " \
                "`paths` or `data` must be given."

    input_schema(
      type: "object",
      properties: {
        element: { type: "string", description: "Human-readable description of the element, for logging." },
        target:  { type: "string", description: "Exact target/ref returned by browser_snapshot." },
        paths: {
          type: "array",
          items: { type: "string" },
          description: "Absolute paths to files to drop onto the element."
        },
        data: {
          type: "object",
          description: "Data to drop, as a map of MIME type to string value " \
                       "(e.g. {\"text/plain\": \"hello\", \"text/uri-list\": \"https://example.com\"})."
        }
      },
      required: %w[target]
    )

    argument_aliases target: %i[ref]
    proxies "browser_drop", element: "element", target: "target", paths: "paths", data: "data"

    class << self
      def call(server_context:, **params)
        if params[:paths].blank? && params[:data].blank?
          return error("browser tool #{tool_name} requires at least one of paths or data.")
        end

        super
      end
    end
  end
end
