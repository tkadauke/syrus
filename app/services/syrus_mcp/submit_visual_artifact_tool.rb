require "mcp"
require "base64"

module SyrusMcp
  # Image-capable sibling to SubmitArtifactTool. Accepts a base64-encoded
  # image (e.g. a browser screenshot) and persists it as an ActiveStorage
  # blob on the current Workflow (mirroring the has_one_attached
  # :coverage_hit_map pattern), then records a 'typed_artifacts' entry
  # pointing at it so the job detail UI's Artifacts tab can render it
  # through a registered :image_diff renderer.
  class SubmitVisualArtifactTool < MCP::Tool
    tool_name "submit_visual_artifact"

    MAX_IMAGE_BYTES = 10.megabytes
    ALLOWED_CONTENT_TYPES = %w[image/png image/jpeg image/webp].freeze
    DEFAULT_CONTENT_TYPE = "image/png"
    EXTENSIONS = { "image/png" => "png", "image/jpeg" => "jpg", "image/webp" => "webp" }.freeze

    description <<~DESC
      Stores a base64-encoded image (e.g. a browser screenshot) as a typed
      artifact on the current Workflow, persisted via ActiveStorage. type is
      a free-form string identifier; if a registered :artifact_renderer maps
      it to the :image_diff renderer, the job detail UI's Artifacts tab
      displays the image directly. If an entry with the same type already
      exists, it is replaced (both the typed_artifacts entry and the stored
      image blob).
    DESC

    input_schema(
      properties: {
        type: {
          type: "string",
          description: "Artifact type identifier (e.g. 'visual_review_screenshot')."
        },
        title: {
          type: "string",
          description: "Human-readable title for the artifact."
        },
        image_base64: {
          type: "string",
          description: "Base64-encoded image bytes (no data: URI prefix)."
        },
        content_type: {
          type: "string",
          description: "Image MIME type. One of image/png, image/jpeg, image/webp. Defaults to image/png."
        }
      },
      required: %w[type title image_base64]
    )

    class << self
      def call(type:, title:, image_base64:, server_context:, content_type: nil)
        run = Mcp::Tools.run_from_context(server_context)
        context = McpToolContext.from_run(run)
        return Mcp::Tools.not_authorized unless McpToolPolicy.capability_permitted?(context, :submit_visual_artifact)

        artifact_type  = Mcp::Tools.utf8(type).strip
        artifact_title = Mcp::Tools.utf8(title).strip
        mime_type      = Mcp::Tools.utf8(content_type).strip.presence || DEFAULT_CONTENT_TYPE

        return Mcp::Tools.invalid("type is required")  if artifact_type.empty?
        return Mcp::Tools.invalid("title is required") if artifact_title.empty?
        unless ALLOWED_CONTENT_TYPES.include?(mime_type)
          return Mcp::Tools.invalid("content_type must be one of #{ALLOWED_CONTENT_TYPES.join(', ')}")
        end

        image_data = decode_image(image_base64)
        return Mcp::Tools.invalid("image_base64 is not valid base64 image data") if image_data.nil?
        return Mcp::Tools.invalid("image_base64 is empty") if image_data.empty?
        if image_data.bytesize > MAX_IMAGE_BYTES
          return Mcp::Tools.invalid("image exceeds maximum size of #{MAX_IMAGE_BYTES / 1.megabyte} MB")
        end

        workflow = run.workflow
        filename = "#{artifact_type.parameterize.presence || 'visual-artifact'}.#{EXTENSIONS.fetch(mime_type, 'png')}"
        workflow.attach_visual_artifact!(type: artifact_type, data: image_data, content_type: mime_type, filename: filename)

        workflow.set_typed_artifact!(
          type: artifact_type,
          title: artifact_title,
          payload: {
            "content_type" => mime_type,
            "byte_size"    => image_data.bytesize,
            "image_url"    => "/api/v1/app/workflows/#{workflow.id}/visual_artifact?type=#{CGI.escape(artifact_type)}"
          }
        )

        Mcp::Tools.write_log(
          run,
          "[mcp] submit_visual_artifact: #{artifact_type.inspect} — #{artifact_title.truncate(60)} (#{image_data.bytesize} bytes)"
        )

        MCP::Tool::Response.new([ { type: "text", text: "Saved." } ])
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::SubmitVisualArtifactTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      # Returns decoded bytes (possibly empty, for blank/empty input — the
      # caller distinguishes "" from nil to give a more specific error) or
      # nil when the input isn't valid base64 at all.
      def decode_image(image_base64)
        Base64.strict_decode64(Mcp::Tools.utf8(image_base64).strip)
      rescue ArgumentError
        nil
      end
    end
  end
end
