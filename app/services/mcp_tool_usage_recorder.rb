class McpToolUsageRecorder
  Result = Struct.new(:server_name, :tool_name, :normalized_tool_name, keyword_init: true)

  MCP_PREFIX = "mcp__".freeze

  def self.record_workflow_tool_call(run:, tool_name:, tool_use_id: nil, tool_input: nil)
    new(surface: "workflow", run: run).record_call(tool_name: tool_name, tool_use_id: tool_use_id, tool_input: tool_input)
  end

  def self.record_workflow_tool_result(run:, tool_name: nil, tool_use_id: nil, content: nil, error: false)
    new(surface: "workflow", run: run).record_result(tool_name: tool_name, tool_use_id: tool_use_id, content: content, error: error)
  end

  def self.record_chat_tool_call(chat_session:, tool_name:, tool_use_id: nil, tool_input: nil, provider: nil)
    new(surface: "chat", chat_session: chat_session, provider: provider)
      .record_call(tool_name: tool_name, tool_use_id: tool_use_id, tool_input: tool_input)
  end

  def self.record_chat_tool_result(chat_session:, tool_name: nil, tool_use_id: nil, content: nil, error: false, provider: nil)
    new(surface: "chat", chat_session: chat_session, provider: provider)
      .record_result(tool_name: tool_name, tool_use_id: tool_use_id, content: content, error: error)
  end

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
    [
      SyrusMcp::ReadLiveStateTool,
      Mcp::Tools::ReadMemoryTool,
      Mcp::Tools::WriteMemoryTool,
      Mcp::Tools::DeleteMemoryTool,
      Mcp::Tools::SearchMemoriesTool,
      Mcp::Tools::ListMemoriesTool,
      SyrusMcp::GetCoverageReportTool,
      SyrusMcp::ReportMainConcernTool,
      SyrusMcp::SubmitSummaryTool,
      SyrusMcp::SubmitTestPlanTool,
      SyrusMcp::SubmitAdversarialReviewTool,
      SyrusMcp::SubmitReconciliationFeedbackTool,
      SyrusMcp::SubmitInsightTool,
      SyrusMcp::ListInsightsTool,
      SyrusMcp::ReadInsightTool
    ].map { |tool| tool.tool_name.to_s }.uniq.sort
  end

  def self.chat_tool_names
    (SyrusChatMcp::Sidecar.tool_names + SyrusChatMcp::DeferredSidecar.tool_names).uniq.sort
  end

  def initialize(surface:, run: nil, chat_session: nil, provider: nil)
    @surface = surface
    @run = run
    @chat_session = chat_session
    @provider = provider
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

  def record_result(tool_name:, tool_use_id:, content:, error:)
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
    if @run
      workflow = @run.workflow
      job = @run.job
      {
        surface: @surface,
        provider: @provider || @run.agent_provider,
        session_id: @run.live_session_id || @run.claude_session&.session_id,
        tool_use_id: tool_use_id,
        user: @run.user,
        repository: job&.repository,
        job: job,
        workflow: workflow,
        run: @run
      }
    else
      {
        surface: @surface,
        provider: @provider || @chat_session&.effective_chat_provider,
        tool_use_id: tool_use_id,
        user: @chat_session&.user,
        repository: @chat_session&.repository,
        chat_session: @chat_session
      }
    end
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
             value.filter_map { |item| item["text"] if item.is_a?(Hash) }.join("\n").presence || value.to_json
           else
             value.to_s
           end
    text.to_s.squish.truncate(McpToolUsage::ERROR_SUMMARY_MAX_LENGTH)
  rescue JSON::GeneratorError
    value.to_s.squish.truncate(McpToolUsage::ERROR_SUMMARY_MAX_LENGTH)
  end
end
