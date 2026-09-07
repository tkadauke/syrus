module SyrusBrowser
  # DOC-17's first concrete RuntimeSessionProvider: a headless-Chromium
  # session driving the repo's own dev server, via the same
  # PreviewProcessLauncher / Mcp::Tools::AgentPreviewRegistry the workflow
  # start_preview MCP tool uses -- one dev-server-start-and-health-check
  # implementation shared across both call sites, not two.
  #
  # `snapshot`/`inspect` deliberately delegate into the browser_* MCP tool
  # classes (ScreenshotTool/SnapshotTool) rather than re-driving Playwright
  # directly: those tools are the ones Coding Mode agents already call by
  # name for semantic targeting (see SessionContext), so routing this
  # provider's own capture paths through them keeps exactly one
  # implementation of "how a browser session is driven," not two.
  class RuntimeSessionProvider
    include Syrus::Plugin::RuntimeSessionProvider

    SessionNotFoundError = Class.new(StandardError)

    DEFAULT_PORT = 3001

    class << self
      def provider_key = "browser"
      def display_name = "Browser"

      # A repository/workspace is a candidate for the browser provider when
      # it has a resolvable preview start command -- the same signal
      # start_preview already uses to decide whether the "Start Preview"
      # affordance should exist at all.
      def detect(_repository, config)
        workspace_path = config[:workspace_path] || config["workspace_path"]
        return false if workspace_path.blank?

        PreviewCommandSource.new(workspace_path).resolve.present?
      end

      def capabilities(_repository, _config)
        {
          stream: "screenshot",
          input: %w[pointer keyboard],
          inspect: %w[dom],
          build: %w[dev_server hot_reload],
          artifacts: %w[screenshots logs]
        }
      end
    end

    def start_session(workspace_ref, config)
      config = config.to_h.symbolize_keys
      port = Integer(config[:port] || DEFAULT_PORT)

      result = PreviewProcessLauncher.new(workspace_ref).launch!(key: workspace_ref, port: port)

      { workspace_ref: workspace_ref, pid: result.pid, port: result.port, url: result.url }
    end

    def build_or_reload(session_id, options)
      runtime_session = find_runtime_session(session_id)
      Mcp::Tools::AgentPreviewRegistry.kill(runtime_session.workspace_ref)
      start_session(runtime_session.workspace_ref, options)
    end

    def launch(session_id, options)
      runtime_session = find_runtime_session(session_id)
      options = options.to_h.symbolize_keys
      preview = running_preview_for!(runtime_session)

      url = options[:url].presence || "http://127.0.0.1:#{preview[:port]}#{options[:path].presence || '/'}"
      response = NavigateTool.call(server_context: browser_context_for(runtime_session), url: url)
      tool_response_to_hash(response)
    end

    def snapshot(session_id, options = {})
      runtime_session = find_runtime_session(session_id)
      params = options.to_h.symbolize_keys.slice(:element, :target)

      response = ScreenshotTool.call(server_context: browser_context_for(runtime_session), **params)
      tool_response_to_hash(response)
    end

    # `session_id` defaults to nil (rather than being required) so a bare
    # `#inspect` call — RSpec failure output, pry, logging — raises
    # NotImplementedError instead of an ArgumentError; see the interface
    # module's own doc comment.
    def inspect(session_id = nil, options = nil)
      raise NotImplementedError, "#{self.class}#inspect requires a session_id" if session_id.nil?

      runtime_session = find_runtime_session(session_id)
      response = SnapshotTool.call(server_context: browser_context_for(runtime_session))
      tool_response_to_hash(response)
    end

    # The control-lease Job gates real pointer/keyboard delivery; until that
    # lands, any input event is safely a no-op rather than driving a shared
    # browser session with no arbitration.
    def input(_session_id, _event)
      { error: "not_yet_supported", message: "browser input is not yet supported by this runtime session provider" }
    end

    def logs(session_id, cursor, _options)
      runtime_session = find_runtime_session(session_id)
      log_path = resolved_log_path(runtime_session.workspace_ref)
      return { entries: [], cursor: cursor.to_i } unless log_path && File.exist?(log_path)

      lines = File.readlines(log_path, chomp: true)
      start_index = cursor.to_i.clamp(0, lines.size)
      entries = lines[start_index..] || []

      { entries: entries, cursor: start_index + entries.size }
    end

    def stop_session(session_id)
      runtime_session = find_runtime_session(session_id)
      SessionRegistry.kill(SessionContext.for_runtime_session(runtime_session).session_key)
      Mcp::Tools::AgentPreviewRegistry.kill(runtime_session.workspace_ref)
      true
    end

    private

    def find_runtime_session(session_id)
      return session_id if session_id.is_a?(RuntimeSession)

      RuntimeSession.find(session_id)
    end

    def running_preview_for!(runtime_session)
      Mcp::Tools::AgentPreviewRegistry.get(runtime_session.workspace_ref) ||
        raise(SessionNotFoundError, "no running dev server for session #{runtime_session.id} — call start_session first")
    end

    def browser_context_for(runtime_session)
      { runtime_session: runtime_session }
    end

    def tool_response_to_hash(response)
      { error: response.error?, content: response.content }
    end

    def resolved_log_path(workspace_path)
      source = PreviewCommandSource.new(workspace_path).resolve
      raw_path = source&.log_paths&.first
      return nil if raw_path.blank?

      Pathname.new(raw_path).absolute? ? raw_path : File.expand_path(raw_path, workspace_path)
    end
  end
end
