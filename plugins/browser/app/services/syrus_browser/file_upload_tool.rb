require "mcp"

module SyrusBrowser
  # Maps to Playwright MCP's "browser_file_upload": responds to a file chooser (opened by a
  # click on a file input or similar) with the given absolute file paths. Covers the
  # file-picker attachment path — a real, valid partial substitute for scenarios that don't
  # specifically require simulating drag-and-drop.
  class FileUploadTool < BrowserTool
    tool_name "browser_file_upload"

    description "Respond to an open file chooser with one or more absolute file paths to " \
                "upload, or call with no paths to cancel the chooser. Use this for " \
                "file-picker/<input type=\"file\"> attachment flows; use browser_evaluate " \
                "instead for native drag-and-drop onto a drop zone."

    input_schema(
      type: "object",
      properties: {
        paths: {
          type: "array",
          items: { type: "string" },
          description: "Absolute paths to the files to upload. Omit to cancel the file chooser."
        }
      },
      required: []
    )

    proxies "browser_file_upload", paths: "paths"
  end
end
