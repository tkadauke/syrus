require "mcp"

module Mockups
  # Read-only: renders an open panel's current (unpublished) scratch state and
  # returns the screenshot as an image block. Never creates a version, changes
  # the panel, or broadcasts -- publishing stays show_preview's job.
  class RenderPreviewTool < MCP::Tool
    extend ToolSupport

    tool_name "render_preview"

    description "Render and visually inspect a preview panel's current UNPUBLISHED scratch files as a " \
                "PNG screenshot returned directly as image content, without publishing anything. " \
                "Strongly recommended workflow: show_preview (no panel_id) to open a panel, " \
                "write_preview_file/edit_preview_file to build it, render_preview to inspect " \
                "representative desktop and mobile states, fix any visible defects (clipped or off-center " \
                "content, malformed SVG, duplicate SVG ids, overflow), and only then publish with " \
                "show_preview(panel_id: ...). This is guidance, not a gate: publish anyway if rendering is " \
                "unavailable or inappropriate. Read-only: does not create a version, change the panel's " \
                "current version, or notify the operator, so the operator still must not be told the preview " \
                "is visible until the publishing show_preview succeeds. For animation- or interaction-heavy " \
                "mockups, pick a suitable wait_ms or a representative state before inspecting. " \
                "viewport is one of desktop (1280x800), tablet (768x1024) or mobile (393x852); " \
                "alternatively pass explicit width (200-2560) and height (200-4000). wait_ms is 0-10000. " \
                "Only the panel's own scratch files and loopback are reachable for the capture."

    input_schema(
      type: "object",
      required: %w[panel_id],
      properties: {
        panel_id:   { type: "string", description: "Open preview panel id, from show_preview." },
        viewport:   { type: "string", enum: PreviewRenderer::VIEWPORT_PRESETS.keys, description: "Viewport preset. Defaults to desktop. Ignored when width and height are given." },
        width:      { type: "integer", description: "Explicit viewport width in CSS pixels (200-2560). Requires height." },
        height:     { type: "integer", description: "Explicit viewport height in CSS pixels (200-4000). Requires width." },
        full_page:  { type: "boolean", description: "Capture the full scrollable page instead of just the viewport. Defaults to false." },
        wait_ms:    { type: "integer", description: "Milliseconds to wait after load before capturing, 0-10000, so animation or loaded state can settle. Defaults to 0." },
        entry_file: { type: "string", description: "Scratch-relative file to render. Defaults to index.html." }
      }
    )

    class << self
      def call(chat_session:, server_context: nil, panel_id: nil, viewport: nil, width: nil, height: nil,
               full_page: false, wait_ms: nil, entry_file: nil)
        panel = find_open_panel(chat_session, panel_id)
        return panel_not_found_response(panel_id) unless panel

        scratch = ScratchDirectory.new(chat_session, panel.id)
        entry = entry_file.presence || PreviewPanel::DEFAULT_ENTRY_FILENAME
        unless scratch.exist?(entry)
          return error_response("entry_file #{entry.inspect} was not found among the scratch files: " \
                                "#{scratch.files.keys.sort.join(', ').presence || '(none yet -- use write_preview_file first)'}.")
        end

        result = PreviewRenderer.new(
          scratch: scratch, panel_id: panel.id, entry_file: entry, preset: viewport,
          width: width, height: height, full_page: truthy?(full_page), wait_ms: wait_ms
        ).render

        MCP::Tool::Response.new([
          { type: "image", data: result.image_data, mimeType: result.mime_type },
          { type: "text", text: JSON.generate(
            panel_id: panel.id, entry_file: result.entry_file, viewport: result.viewport,
            preset: result.preset, capture: result.full_page ? "full_page" : "viewport",
            wait_ms: result.wait_ms, published: false,
            note: "Unpublished scratch render; call show_preview with this panel_id to publish."
          ) }
        ])
      rescue PreviewRenderer::InvalidRequest => e
        error_response(e.message)
      rescue PreviewRenderer::Unavailable => e
        error_response("Could not render the preview: #{e.message}. Publish with show_preview if inspection is not possible.")
      end
    end
  end
end
