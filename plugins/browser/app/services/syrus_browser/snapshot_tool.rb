require "mcp"

module SyrusBrowser
  class SnapshotTool < BrowserTool
    tool_name "browser_snapshot"

    description "Capture an accessibility-tree snapshot of the current page. Each interactive " \
                "element gets a stable `target`/`ref` you can pass to browser_click / browser_fill to " \
                "target it precisely, instead of guessing CSS selectors. Call this after " \
                "navigating, and again after any action that changes the page."

    input_schema(type: "object", properties: {}, required: [])

    proxies "browser_snapshot"
  end
end
