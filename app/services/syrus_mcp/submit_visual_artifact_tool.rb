require "mcp"
require "base64"

module SyrusMcp
  # Image-capable sibling to SubmitArtifactTool. Accepts an image file path
  # inside the workflow workspace or base64-encoded image bytes and persists it
  # as an ActiveStorage
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
      Stores an image (e.g. a browser screenshot) as a typed artifact on the
      current Workflow, persisted via ActiveStorage. Prefer image_path for files
      already saved in the workflow workspace, such as browser_screenshot output;
      image_base64 remains available when bytes are already in memory. type is a
      free-form string identifier; visual-review screenshots are persisted under
      run-scoped internal artifact types so later review iterations do not
      overwrite earlier evidence.
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
          description: "Base64-encoded image bytes (no data: URI prefix). Use exactly one of image_base64 or image_path."
        },
        image_path: {
          type: "string",
          description: "Path to an image file in the workflow workspace, relative to the workspace root or absolute within it. Prefer this for browser_screenshot output. Use exactly one of image_base64 or image_path."
        },
        content_type: {
          type: "string",
          description: "Image MIME type. One of image/png, image/jpeg, image/webp. Defaults from image_path extension, else image/png."
        }
      },
      required: %w[type title]
    )

    class << self
      def call(type:, title:, server_context:, image_base64: nil, image_path: nil, content_type: nil)
        run = Mcp::Tools.run_from_context(server_context)
        context = McpToolContext.from_run(run)
        return Mcp::Tools.not_authorized unless McpToolPolicy.capability_permitted?(context, :submit_visual_artifact)

        artifact_type  = Mcp::Tools.utf8(type).strip
        artifact_title = Mcp::Tools.utf8(title).strip
        image_source   = normalize_image_source(image_base64: image_base64, image_path: image_path)
        mime_type      = Mcp::Tools.utf8(content_type).strip.presence || inferred_content_type(image_source[:path])

        return Mcp::Tools.invalid("type is required")  if artifact_type.empty?
        return Mcp::Tools.invalid("title is required") if artifact_title.empty?
        return Mcp::Tools.invalid(image_source[:error]) if image_source[:error]
        unless ALLOWED_CONTENT_TYPES.include?(mime_type)
          return Mcp::Tools.invalid("content_type must be one of #{ALLOWED_CONTENT_TYPES.join(', ')}")
        end

        image_data = read_image_data(image_source, run)
        return Mcp::Tools.invalid(image_data[:error]) if image_data[:error]
        image_data = image_data[:data]
        return Mcp::Tools.invalid("image data is empty") if image_data.empty?
        if image_data.bytesize > MAX_IMAGE_BYTES
          return Mcp::Tools.invalid("image exceeds maximum size of #{MAX_IMAGE_BYTES / 1.megabyte} MB")
        end

        workflow = run.workflow
        stored_type = stored_artifact_type(workflow, run, artifact_type)
        filename = "#{stored_type.parameterize.presence || 'visual-artifact'}.#{EXTENSIONS.fetch(mime_type, 'png')}"
        workflow.attach_visual_artifact!(type: stored_type, data: image_data, content_type: mime_type, filename: filename)

        workflow.set_typed_artifact!(
          type: stored_type,
          title: artifact_title,
          original_type: artifact_type,
          renderer_type: :image_diff,
          payload: {
            "content_type" => mime_type,
            "byte_size"    => image_data.bytesize,
            "image_url"    => "/api/v1/app/workflows/#{workflow.id}/visual_artifact?type=#{CGI.escape(stored_type)}",
            "run_id"       => run.id,
            "step_id"      => run.step_id,
            "iteration"    => run.step&.iteration,
            "original_type" => artifact_type
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

      def normalize_image_source(image_base64:, image_path:)
        encoded = Mcp::Tools.utf8(image_base64).strip.presence
        path = Mcp::Tools.utf8(image_path).strip.presence
        return { error: "provide exactly one of image_path or image_base64" } if encoded.present? && path.present?
        return { error: "image_path or image_base64 is required" } if encoded.blank? && path.blank?

        encoded.present? ? { kind: :base64, value: encoded } : { kind: :path, path: path }
      end

      def read_image_data(image_source, run)
        case image_source[:kind]
        when :base64
          data = decode_image(image_source[:value])
          return { error: "image_base64 is not valid base64 image data" } if data.nil?

          { data: data }
        when :path
          path = safe_image_path(image_source[:path], run)
          return { error: "image_path must point to a file inside the workflow workspace" } unless path
          return { error: "image_path not found: #{image_source[:path]}" } unless File.file?(path)
          return { error: "image exceeds maximum size of #{MAX_IMAGE_BYTES / 1.megabyte} MB" } if File.size(path) > MAX_IMAGE_BYTES

          { data: File.binread(path) }
        else
          { error: "image_path or image_base64 is required" }
        end
      end

      def safe_image_path(path, run)
        workflow = run.workflow
        return unless workflow

        workspace = WorkflowWorkspace.path_for(workflow)
        return unless workspace.exist?

        candidate = File.expand_path(path, workspace.to_s)
        real_workspace = File.realpath(workspace.to_s)
        real_candidate = File.realpath(candidate)
        return unless real_candidate == real_workspace || real_candidate.start_with?(real_workspace + File::SEPARATOR)

        real_candidate
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end

      def inferred_content_type(path)
        case File.extname(path.to_s).downcase
        when ".jpg", ".jpeg" then "image/jpeg"
        when ".webp" then "image/webp"
        else DEFAULT_CONTENT_TYPE
        end
      end

      def stored_artifact_type(workflow, run, artifact_type)
        base = artifact_type.parameterize(separator: "_").presence || "visual_artifact"
        existing_count = Array(workflow.artifact("typed_artifacts")).count do |entry|
          entry.is_a?(Hash) &&
            entry["original_type"] == artifact_type &&
            entry.dig("payload", "run_id").to_i == run.id
        end
        "#{base}_run_#{run.id}_#{existing_count + 1}"
      end
    end
  end
end
