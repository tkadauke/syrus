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
      capture_current_browser to capture from the active MCP browser session
      without copying temp files, omit image inputs to default to that same
      current-browser capture, and use image_base64 only when bytes are already
      in memory. type is a free-form string identifier; visual-review
      screenshots are persisted under run-scoped internal artifact types so
      later review iterations do not overwrite earlier evidence.
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
          description: "Base64-encoded image bytes (no data: URI prefix). Use exactly one of image_base64, image_path, or capture_current_browser; omit all three to capture the current browser."
        },
        image_path: {
          type: "string",
          description: "Path to an image file in the workflow workspace, relative to the workspace root or absolute within it. Prefer this for existing files. Use exactly one of image_base64, image_path, or capture_current_browser; omit all three to capture the current browser."
        },
        capture_current_browser: {
          type: "boolean",
          description: "When true, capture the current authenticated MCP browser page directly and submit that screenshot. This is also the default when image_base64 and image_path are omitted."
        },
        content_type: {
          type: "string",
          description: "Image MIME type. One of image/png, image/jpeg, image/webp. Defaults from image_path extension, else image/png."
        }
      },
      required: %w[type title]
    )

    class << self
      def call(type:, title:, server_context:, image_base64: nil, image_path: nil, capture_current_browser: false, content_type: nil)
        run = Mcp::Tools.run_from_context(server_context)
        context = McpToolContext.from_run(run)
        return Mcp::Tools.not_authorized unless McpToolPolicy.capability_permitted?(context, :submit_visual_artifact)

        artifact_type  = Mcp::Tools.utf8(type).strip
        artifact_title = Mcp::Tools.utf8(title).strip
        image_source   = normalize_image_source(image_base64: image_base64, image_path: image_path, capture_current_browser: capture_current_browser)
        explicit_content_type = Mcp::Tools.utf8(content_type).strip.presence

        return Mcp::Tools.invalid("type is required")  if artifact_type.empty?
        return Mcp::Tools.invalid("title is required") if artifact_title.empty?
        return Mcp::Tools.invalid(image_source[:error]) if image_source[:error]

        captured = read_image_data(image_source, run)
        return Mcp::Tools.invalid(captured[:error]) if captured[:error]

        image_data = captured.fetch(:data)
        mime_type = explicit_content_type || captured[:content_type].presence || inferred_content_type(image_source[:path])
        unless ALLOWED_CONTENT_TYPES.include?(mime_type)
          return Mcp::Tools.invalid("content_type must be one of #{ALLOWED_CONTENT_TYPES.join(', ')}")
        end
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
          payload: visual_artifact_payload(
            workflow: workflow,
            run: run,
            stored_type: stored_type,
            original_type: artifact_type,
            source: captured[:source],
            content_type: mime_type,
            byte_size: image_data.bytesize,
            metadata: captured[:metadata]
          ),
          **TypedArtifactProvenance.for_run(run)
        )

        Mcp::Tools.write_log(
          run,
          "[mcp] submit_visual_artifact: #{artifact_type.inspect} — #{artifact_title.truncate(60)} (#{image_data.bytesize} bytes)"
        )

        MCP::Tool::Response.new([ { type: "text", text: "Saved as artifact type #{stored_type.inspect}. Reference this exact type from submit_report to include it in the report." } ])
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

      def normalize_image_source(image_base64:, image_path:, capture_current_browser:)
        encoded_text = Mcp::Tools.utf8(image_base64).strip
        path_text = Mcp::Tools.utf8(image_path).strip
        return { error: "image_base64 is empty" } if !image_base64.nil? && encoded_text.blank?
        return { error: "image_path is empty" } if !image_path.nil? && path_text.blank?

        encoded = encoded_text.presence
        path = path_text.presence
        current_browser = ActiveModel::Type::Boolean.new.cast(capture_current_browser)
        source_count = [ encoded.present?, path.present?, current_browser ].count(true)
        return { error: "provide exactly one of image_path, image_base64, or capture_current_browser" } if source_count > 1

        return { kind: :base64, value: encoded, source: "base64" } if encoded.present?
        return { kind: :path, path: path, source: "image_path" } if path.present?

        { kind: :current_browser, source: "current_browser" }
      end

      def read_image_data(image_source, run)
        case image_source[:kind]
        when :base64
          data = decode_image(image_source[:value])
          return { error: "image_base64 is not valid base64 image data" } if data.nil?

          { data: data, source: image_source[:source] }
        when :path
          path = safe_image_path(image_source[:path], run)
          return { error: "image_path must point to a file inside the workflow workspace" } unless path
          return { error: "image_path not found: #{image_source[:path]}" } unless File.file?(path)
          return { error: "image exceeds maximum size of #{MAX_IMAGE_BYTES / 1.megabyte} MB" } if File.size(path) > MAX_IMAGE_BYTES

          { data: File.binread(path), source: image_source[:source] }
        when :current_browser
          capture_current_browser(run)
        else
          { error: "image_path, image_base64, or capture_current_browser is required" }
        end
      end

      def capture_current_browser(run)
        response = call_browser_tool(run, "browser_screenshot", {})
        return { error: "current browser screenshot failed: #{tool_error_text(response)}" } if response.nil? || response.error?

        image = response.content.find { |block| block.is_a?(Hash) && block[:type] == "image" && block[:data].present? }
        return { error: "current browser screenshot did not return image data" } unless image

        data = decode_image(image[:data])
        return { error: "current browser screenshot returned invalid image data" } if data.nil?

        {
          data: data,
          source: "current_browser",
          content_type: image[:mimeType].presence || image[:mime_type].presence || DEFAULT_CONTENT_TYPE,
          metadata: current_browser_metadata(run)
        }
      end

      def current_browser_metadata(run)
        response = call_browser_tool(
          run,
          "browser_evaluate",
          {
            "function" => <<~JS.squish
              () => ({
                url: window.location.href,
                path: window.location.pathname + window.location.search + window.location.hash,
                title: document.title,
                viewport: {
                  width: window.innerWidth,
                  height: window.innerHeight,
                  deviceScaleFactor: window.devicePixelRatio
                }
              })
            JS
          }
        )
        return {} if response.nil? || response.error?

        text = response.content.find { |block| block.is_a?(Hash) && block[:type] == "text" }&.dig(:text)
        parsed = parse_browser_evaluate_json(text)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError, TypeError
        {}
      end

      def parse_browser_evaluate_json(text)
        body = text.to_s.strip
        return JSON.parse(body) if body.present?

        {}
      rescue JSON::ParserError
        section = body[/(?:\A|\n)### Result\s*\n(?<result>.*?)(?=\n### |\z)/m, :result].to_s.strip
        return {} if section.blank?

        JSON.parse(section)
      end

      def call_browser_tool(run, tool_name, params)
        provider = browser_tool_provider(run, tool_name)
        return unless provider

        provider.new.handle(tool_name, params, { run: run })
      end

      def browser_tool_provider(run, tool_name)
        context = McpToolContext.from_run(run)
        Syrus::PluginRegistry.providers_for(:mcp_tool_set).find do |provider|
          next false unless provider_available_for_context?(provider, context)

          provider_tool_names(provider, context).include?(tool_name)
        end
      rescue StandardError => e
        Rails.logger.warn("[SyrusMcp::SubmitVisualArtifactTool] browser provider lookup failed: #{e.class}: #{e.message}")
        nil
      end

      def provider_available_for_context?(provider, context)
        if provider.respond_to?(:available_for_context?)
          provider.available_for_context?(context)
        else
          provider.available_for?(context.repository)
        end
      end

      def provider_tool_names(provider, context)
        definitions =
          if provider.method(:tool_definitions).parameters.any? { |type, name| [ :key, :keyreq ].include?(type) && name == :context }
            provider.tool_definitions(context: context)
          else
            provider.tool_definitions
          end
        definitions.filter_map { |definition| definition[:name] || definition["name"] }
      end

      def tool_error_text(response)
        response&.content&.first&.dig(:text).presence || "browser tool unavailable"
      end

      def visual_artifact_payload(workflow:, run:, stored_type:, original_type:, source:, content_type:, byte_size:, metadata:)
        payload = {
          "content_type" => content_type,
          "byte_size"    => byte_size,
          "image_url"    => "/api/v1/app/workflows/#{workflow.id}/visual_artifact?type=#{CGI.escape(stored_type)}",
          "run_id"       => run.id,
          "step_id"      => run.step_id,
          "iteration"    => run.step&.iteration,
          "original_type" => original_type,
          "source"       => source,
          "captured_at"  => Time.current.iso8601(3)
        }
        payload.merge!(provenance_metadata(metadata))
        payload
      end

      def provenance_metadata(metadata)
        metadata = metadata.to_h
        page = {
          "url" => metadata["url"].presence,
          "path" => metadata["path"].presence,
          "title" => metadata["title"].presence
        }.compact
        viewport = metadata["viewport"].is_a?(Hash) ? metadata["viewport"].slice("width", "height", "deviceScaleFactor", "device_scale_factor").compact : {}

        {}.tap do |payload|
          payload["page"] = page if page.present?
          payload["viewport"] = normalize_viewport(viewport) if viewport.present?
        end
      end

      def normalize_viewport(viewport)
        {
          "width" => viewport["width"],
          "height" => viewport["height"],
          "device_scale_factor" => viewport["deviceScaleFactor"] || viewport["device_scale_factor"]
        }.compact
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
