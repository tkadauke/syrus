require "mcp"

module SyrusBrowser
  class WaitForTool < BrowserTool
    tool_name "browser_wait_for"

    description "Wait for text to appear or disappear on the page, or for a fixed number of seconds."

    input_schema(
      type: "object",
      properties: {
        text:      { type: "string", description: "Wait until this text appears on the page." },
        text_gone: { type: "string", description: "Wait until this text is no longer on the page." },
        time:      { type: "number", description: "Wait this many seconds instead of watching for text." }
      },
      required: []
    )

    proxies "browser_wait_for", text: "text", text_gone: "textGone", time: "time"
  end
end
