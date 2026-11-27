require "mcp"

module SyrusBrowser
  class PressKeyTool < BrowserTool
    tool_name "browser_press_key"
    description "Press a keyboard key or chord through Playwright (for example Enter or Control+S)."
    input_schema(type: "object", properties: { key: { type: "string", description: "Key or chord in Playwright notation." } }, required: %w[key])
    proxies "browser_press_key", key: "key"
    requires_input_lease!
  end
end
