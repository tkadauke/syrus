require "mcp"

module SyrusBrowser
  class ResizeTool < BrowserTool
    tool_name "browser_resize"

    description "Resize the browser viewport to the given width and height in CSS pixels. Use this to test " \
                "responsive layouts at different screen sizes (e.g. desktop vs. mobile) within the same session."

    input_schema(
      type: "object",
      properties: {
        width:  { type: "integer", description: "Viewport width in CSS pixels." },
        height: { type: "integer", description: "Viewport height in CSS pixels." }
      },
      required: %w[width height]
    )

    proxies "browser_resize", width: "width", height: "height"
  end
end
