require_relative "lib/whiteboard_tools/version"

Gem::Specification.new do |spec|
  spec.name    = "whiteboard_tools"
  spec.version = WhiteboardTools::VERSION
  spec.authors = ["Thomas Kadauke"]
  spec.summary = "Syrus plugin: chat whiteboard workspace tab, MCP drawing tools, and REST endpoints"
  spec.description = "Moves the chat whiteboard feature (Excalidraw workspace tab, draw/move/delete/read/save/" \
    "clear/load MCP tools, and its REST endpoints) out of core and onto the :workspace_tab and " \
    ":chat_mcp_tool_set plugin extension points. The underlying Whiteboard/WhiteboardSnapshot models stay " \
    "in core (same precedent as PreviewPanel for preview_tools) -- only the presentation and tool surface move."
  spec.homepage = "https://github.com/tkadauke/syrus"

  spec.files         = Dir["lib/**/*", "app/**/*"]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.4"

  spec.add_dependency "rails", ">= 8.1"
end
