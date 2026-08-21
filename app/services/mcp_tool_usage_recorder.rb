class McpToolUsageRecorder
  Result = Struct.new(:server_name, :tool_name, :normalized_tool_name, keyword_init: true)

  MCP_PREFIX = "mcp__".freeze

  def self.record_workflow_tool_call(run:, tool_name:, tool_use_id: nil, tool_input: nil, sidecar_mode: "stdio")
    new(surface: "workflow", run: run, sidecar_mode: sidecar_mode)
      .record_call(tool_name: tool_name, tool_use_id: tool_use_id, tool_input: tool_input)
  end

  def self.record_workflow_tool_result(run:, tool_name: nil, tool_use_id: nil, content: nil, error: false, sidecar_mode: "stdio")
    new(surface: "workflow", run: run, sidecar_mode: sidecar_mode)
      .record_result(tool_name: tool_name, tool_use_id: tool_use_id, content: content, error: error)
  end

  def self.record_chat_tool_call(chat_session:, tool_name:, tool_use_id: nil, tool_input: nil, provider: nil, sidecar_mode: "stdio")
    new(surface: "chat", chat_session: chat_session, provider: provider, sidecar_mode: sidecar_mode)
      .record_call(tool_name: tool_name, tool_use_id: tool_use_id, tool_input: tool_input)
  end

  def self.record_chat_tool_result(chat_session:, tool_name: nil, tool_use_id: nil, content: nil, error: false, provider: nil, sidecar_mode: "stdio")
    new(surface: "chat", chat_session: chat_session, provider: provider, sidecar_mode: sidecar_mode)
      .record_result(tool_name: tool_name, tool_use_id: tool_use_id, content: content, error: error)
  end

  # Records a full call+result cycle for a tool dispatched directly at a
  # persistent MCP sidecar's dispatch boundary (EPIC-250,
  # PersistentMcpDaemon::ChatToolDispatch), as opposed to the transcript-
  # derived recording above. Unlike transcript recording -- which observes a
  # "tool_call" event and a later "tool_result" event as two separate points
  # in an agent's own output stream -- the daemon holds the dispatch open for
  # one synchronous call, so there is nothing to correlate across time; a
  # freshly minted tool_use_id exists only to satisfy the shared call+result
  # row shape record_call/record_result already use for transcript mode.
  #
  # Yields the actual dispatch. A block that returns an MCP::Tool::Response
  # records its #error?/#content; any other return value is treated as
  # success. A block that raises is recorded as a failed result carrying the
  # exception's class and message (never the full backtrace or tool
  # input/output), then re-raised so the caller's own error handling is
  # unaffected -- this is what lets a rejection *before* the underlying tool
  # ever runs (invalid invocation context, tier/role authorization) show up
  # as a real usage row instead of vanishing silently.
  # `error_class:` tags a *known* failure reason the caller already has in
  # hand for a block that returns (rather than raises) an error Response --
  # e.g. ChatToolDispatch already caught a specific McpInvocationContext
  # subclass and wants to keep returning a normal tool Response instead of
  # re-raising, but still wants that reason recorded. Ignored unless the
  # yielded response itself signals an error.
  def self.record_dispatch(surface:, tool_name:, tool_input:, sidecar_mode:, daemon_identity: nil,
                            run: nil, chat_session: nil, provider: nil, error_class: nil)
    recorder = new(surface: surface, run: run, chat_session: chat_session, provider: provider,
                    sidecar_mode: sidecar_mode, daemon_identity: daemon_identity)
    tool_use_id = SecureRandom.uuid
    recorder.record_call(tool_name: tool_name, tool_use_id: tool_use_id, tool_input: tool_input)

    begin
      response = yield
      response_error = dispatch_response_error?(response)
      recorder.record_result(
        tool_name: tool_name,
        tool_use_id: tool_use_id,
        content: dispatch_response_content(response),
        error: response_error,
        error_class: response_error ? error_class : nil
      )
      response
    rescue StandardError => e
      recorder.record_result(
        tool_name: tool_name,
        tool_use_id: tool_use_id,
        content: { message: e.message },
        error: true,
        error_class: e.class.name
      )
      raise
    end
  end

  def self.dispatch_response_content(response)
    response.respond_to?(:content) ? response.content : response
  end
  private_class_method :dispatch_response_content

  def self.dispatch_response_error?(response)
    response.respond_to?(:error?) ? response.error? : false
  end
  private_class_method :dispatch_response_error?

  def self.normalize(raw_tool_name)
    raw = raw_tool_name.to_s
    return Result.new(server_name: nil, tool_name: "unknown", normalized_tool_name: "unknown") if raw.blank?

    if raw.start_with?(MCP_PREFIX)
      _prefix, server_name, tool_name = raw.split("__", 3)
      return normalized_result(server_name, tool_name.presence || raw)
    end

    if raw.include?(".")
      server_name, tool_name = raw.split(".", 2)
      return normalized_result(server_name, tool_name)
    end

    normalized_result(nil, raw)
  end

  def self.advertised_tools(surface:)
    case surface.to_s
    when "workflow"
      workflow_tool_names
    when "chat"
      chat_tool_names
    else
      (workflow_tool_names + chat_tool_names).uniq.sort
    end
  end

  def self.workflow_tool_names
    (McpToolRegistry.summaries(surface: :workflow) + McpToolRegistry.summaries(surface: :agent_insight))
      .map { |entry| entry[:tool_name].to_s }
      .uniq
      .sort
  end

  def self.chat_tool_names
    McpToolRegistry.summaries(surface: :chat)
      .map { |entry| entry[:tool_name].to_s }
      .uniq
      .sort
  end

  def initialize(surface:, run: nil, chat_session: nil, provider: nil, sidecar_mode: nil, daemon_identity: nil)
    @surface = surface
    @run = run
    @chat_session = chat_session
    @provider = provider
    @sidecar_mode = sidecar_mode
    @daemon_identity = daemon_identity
  end

  def record_call(tool_name:, tool_use_id:, tool_input:)
    normalized = self.class.normalize(tool_name)
    usage = find_usage(tool_use_id) || McpToolUsage.new(context_attributes(tool_use_id).merge(
      raw_tool_name: tool_name.to_s,
      server_name: normalized.server_name,
      tool_name: normalized.tool_name,
      normalized_tool_name: normalized.normalized_tool_name
    ))
    usage.assign_attributes(
      status: "started",
      started_at: usage.started_at || Time.current,
      input_bytes: byte_count(tool_input)
    )
    usage.save!
    usage
  rescue StandardError => e
    Rails.logger.warn("[McpToolUsageRecorder] call record failed: #{e.class}: #{e.message}")
    nil
  end

  def record_result(tool_name:, tool_use_id:, content:, error:, error_class: nil)
    usage = find_usage(tool_use_id)
    normalized = self.class.normalize(tool_name || usage&.raw_tool_name)
    usage ||= McpToolUsage.new(context_attributes(tool_use_id).merge(
      raw_tool_name: (tool_name.presence || "unknown"),
      server_name: normalized.server_name,
      tool_name: normalized.tool_name,
      normalized_tool_name: normalized.normalized_tool_name,
      started_at: Time.current
    ))
    usage.assign_attributes(
      status: error ? "failed" : "completed",
      error: error == true,
      error_class: error ? error_class : nil,
      completed_at: Time.current,
      result_bytes: byte_count(content),
      error_message_summary: error ? summarize_error(content) : nil
    )
    usage.save!
    usage
  rescue StandardError => e
    Rails.logger.warn("[McpToolUsageRecorder] result record failed: #{e.class}: #{e.message}")
    nil
  end

  private

  def self.normalized_result(server_name, tool_name)
    tool = tool_name.to_s.presence || "unknown"
    Result.new(server_name: server_name.presence, tool_name: tool, normalized_tool_name: tool)
  end
  private_class_method :normalized_result

  def find_usage(tool_use_id)
    return if tool_use_id.blank?

    scope = McpToolUsage.where(surface: @surface, tool_use_id: tool_use_id.to_s)
    scope = scope.where(run_id: @run.id) if @run
    scope = scope.where(chat_session_id: @chat_session.id) if @chat_session
    scope.order(created_at: :desc).first
  end

  def context_attributes(tool_use_id)
    base = { sidecar_mode: @sidecar_mode, daemon_worker_id: daemon_worker_id }

    if @run
      workflow = @run.workflow
      job = @run.job
      base.merge(
        surface: @surface,
        provider: @provider || @run.agent_provider,
        session_id: @run.live_session_id || @run.provider_session&.session_id,
        tool_use_id: tool_use_id,
        user: @run.user,
        repository: job&.repository,
        job: job,
        workflow: workflow,
        run: @run
      )
    else
      base.merge(
        surface: @surface,
        provider: @provider || @chat_session&.effective_chat_provider,
        tool_use_id: tool_use_id,
        user: @chat_session&.user,
        repository: @chat_session&.repository,
        chat_session: @chat_session
      )
    end
  end

  def daemon_worker_id
    return nil if @daemon_identity.blank?

    @daemon_identity[:worker_id] || @daemon_identity["worker_id"]
  end

  def byte_count(value)
    return nil if value.nil?

    JSON.generate(value).bytesize
  rescue JSON::GeneratorError
    value.to_s.bytesize
  end

  def summarize_error(value)
    text = case value
    when Hash
      value["message"] || value[:message] || value["error"] || value[:error] || value.to_json
    when Array
      value.filter_map { |item| (item["text"] || item[:text]) if item.is_a?(Hash) }.join("\n").presence || value.to_json
    else
      value.to_s
    end
    text.to_s.squish.truncate(McpToolUsage::ERROR_SUMMARY_MAX_LENGTH)
  rescue JSON::GeneratorError
    value.to_s.squish.truncate(McpToolUsage::ERROR_SUMMARY_MAX_LENGTH)
  end
end
