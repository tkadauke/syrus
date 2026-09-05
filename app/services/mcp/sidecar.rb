require "mcp"

module Mcp
  class Sidecar
    CHAT_ESSENTIAL_SERVER = "syrus-chat-sidecar"
    CHAT_DEFERRED_SERVER = "syrus-chat-deferred-sidecar"
    WORKFLOW_SERVER = "syrus-mcp-sidecar"

    CHAT_ESSENTIAL_TOOLS = McpToolRegistry.tools(surface: :chat, tier: :essential).freeze
    CHAT_DEFERRED_TOOLS = McpToolRegistry.tools(surface: :chat, tier: :deferred).freeze
    CHAT_ADMIN_TOOLS = McpToolRegistry.entries.select { |entry| entry.surface == :chat && entry.admin_only }.map(&:tool).freeze
    CHAT_WALKTHROUGH_TOOLS = McpToolRegistry.entries.select { |entry| entry.surface == :chat && entry.feature_flag == :video_walkthroughs }.map(&:tool).freeze
    CHAT_CODING_TOOLS = McpToolRegistry.entries.select { |entry| entry.surface == :chat && entry.required_roles.include?(AgentRole::CHAT_CODING) }.map(&:tool).freeze
    CHAT_LOCAL_MODE_TOOLS = McpToolRegistry.entries.select { |entry| entry.surface == :chat && entry.required_roles.include?(AgentRole::CHAT_LOCAL) }.map(&:tool).freeze

    module StdioToolDispatch
      def call(*args, server_context: nil, **kwargs, &block)
        super(*args, server_context: server_context, **kwargs, &block)
      rescue StandardError => e
        Mcp::Sidecar.record_stdio_tool_exception(
          tool_name: McpToolRegistry.tool_name_for(self),
          server_context: server_context,
          exception: e
        )
        raise
      end
    end

    def self.chat(session_id:, current_message_id: nil, tier: :essential, server_name: nil)
      tier = tier.to_sym
      default_name = tier == :deferred ? CHAT_DEFERRED_SERVER : CHAT_ESSENTIAL_SERVER
      evaluator = tier == :evaluator
      new(
        server_name: server_name.presence || default_name,
        tools: -> { chat_tools_for(ChatSession.find(session_id), tier: tier) },
        server_context: -> {
          chat_context(
            ChatSession.find(session_id),
            current_message_id: current_message_id,
            evaluator: evaluator,
            scoped_event_id: ENV["SYRUS_CHAT_SCOPED_EVENT_ID"],
            evaluator_session_id: ENV["SYRUS_CHAT_EVALUATOR_SESSION_ID"]
          )
        }
      )
    end

    def self.workflow(run_id:)
      new(
        server_name: WORKFLOW_SERVER,
        tools: lambda {
          Tools.with_database_connection do
            context = McpToolContext.from_run(Run.includes(:step, job: :repository).find(run_id))
            McpToolPolicy.for(context) + plugin_workflow_tools_for(context)
          end
        },
        server_context: -> { { run_id: run_id } }
      )
    end

    def self.chat_tool_names(chat_session = nil, tier: :essential)
      chat_tools(chat_session, tier: tier).map { |tool| McpToolRegistry.tool_name_for(tool) }
    end

    def self.tool_names(chat_session = nil, tier: :essential)
      chat_tool_names(chat_session, tier: tier)
    end

    def self.chat_tools(chat_session = nil, tier: :essential)
      return McpToolRegistry.tools(surface: :chat, tier: tier) unless chat_session

      chat_tools_for(chat_session, tier: tier)
    end

    def self.chat_tools_for(chat_session, tier:)
      evaluator = tier.to_s == "evaluator"
      context = McpToolContext.from_chat_session(chat_session, evaluator: evaluator)
      if evaluator
        # The evaluator's core set is a fixed read-only allowlist. A plugin
        # joins it by marking a definition `evaluator: true` -- otherwise a
        # tool that moved out of core would silently disappear from here.
        McpToolPolicy.for(context).map { |tool| authorize_tool(tool) } +
          plugin_tools_for(chat_session, tier: :evaluator, policy: :evaluator)
      else
        registry_tier = tier.to_s == "all" ? :essential : tier
        allowed = McpToolRegistry.tools_for_context(context, surface: :chat, tier: registry_tier)
        supervisor = !!context.chat_session&.system_kind_supervisor?
        allowed -= McpToolPolicy::SUPERVISOR_EXCLUDED_TOOLS if supervisor
        tools = allowed.map { |tool| authorize_tool(tool) }
        tools << authorize_tool(Tools::ExplainStuckJobTool) if tier.to_s == "all" && !tools.include?(Tools::ExplainStuckJobTool)
        # Plugin tools are appended after core's supervisor filter, so they
        # have to be filtered on the way in or they bypass it entirely.
        tools + plugin_tools_for(chat_session, tier: registry_tier, policy: (:supervisor if supervisor))
      end
    end

    # Applies the policy flags a plugin tool definition may declare. Nothing
    # to apply for an ordinary chat: a plugin that says nothing keeps every
    # tool it advertises.
    def self.filter_by_policy(definitions, policy)
      case policy
      when :supervisor then definitions.reject { |defn| defn[:supervisor_excluded] || defn["supervisor_excluded"] }
      when :evaluator  then definitions.select { |defn| defn[:evaluator] || defn["evaluator"] }
      else definitions
      end
    end

    def self.plugin_tools_for(chat_session, tier:, policy: nil)
      tool_sets = PerformanceLogging.phase("chat_mcp_sidecar.plugin_tool_sets", chat_id: chat_session.id, tier: tier) do
        Syrus::PluginRegistry.providers_for(:chat_mcp_tool_set)
      end

      tool_sets
        .select do |tool_set|
          PerformanceLogging.plugin_call(extension_point: :chat_mcp_tool_set, provider: tool_set, operation: :available_for) do
            tool_set.available_for?(chat_session, tier: tier)
          end
        end
        .flat_map { |tool_set| mcp_tools_for(tool_set, tier: tier, chat_session: chat_session, policy: policy) }
    end

    def self.mcp_tools_for(tool_set_class, tier:, chat_session: nil, policy: nil)
      definitions = PerformanceLogging.plugin_call(extension_point: :chat_mcp_tool_set, provider: tool_set_class, operation: :tool_definitions) do
        # Optional `chat_session:` keyword, mirroring the workflow side's
        # optional `context:`: a tool set whose advertised set depends on who
        # is asking (an admin-only audit tool, say) cannot decide from the
        # tier alone.
        if tool_set_class.method(:tool_definitions).parameters.any? { |type, name| [ :key, :keyreq ].include?(type) && name == :chat_session }
          tool_set_class.tool_definitions(tier: tier, chat_session: chat_session)
        else
          tool_set_class.tool_definitions(tier: tier)
        end
      end

      definitions = filter_by_policy(definitions, policy)

      definitions.map do |defn|
        MCP::Tool.define(
          name: defn[:name],
          description: defn[:description],
          input_schema: defn[:input_schema]
        ) do |server_context:, **params|
          PerformanceLogging.plugin_call(extension_point: :chat_mcp_tool_set, provider: tool_set_class, operation: "handle.#{defn[:name]}") do
            tool_set_class.new.handle(defn[:name], params, server_context)
          end
        end
      end
    end

    def self.plugin_workflow_tools_for(context)
      tool_sets = PerformanceLogging.phase("workflow_mcp_sidecar.plugin_tool_sets", repository_id: context.repository&.id) do
        Syrus::PluginRegistry.providers_for(:mcp_tool_set)
      end

      tool_sets
        .select do |tool_set|
          PerformanceLogging.plugin_call(extension_point: :mcp_tool_set, provider: tool_set, operation: :available_for) do
            if tool_set.respond_to?(:available_for_context?)
              tool_set.available_for_context?(context)
            else
              tool_set.available_for?(context.repository)
            end
          end
        end
        .flat_map { |tool_set| workflow_mcp_tools_for(tool_set, context: context) }
    end

    def self.workflow_mcp_tools_for(tool_set_class, context:)
      definitions = PerformanceLogging.plugin_call(extension_point: :mcp_tool_set, provider: tool_set_class, operation: :tool_definitions) do
        if tool_set_class.method(:tool_definitions).parameters.any? { |type, name| [ :key, :keyreq ].include?(type) && name == :context }
          tool_set_class.tool_definitions(context: context)
        else
          tool_set_class.tool_definitions
        end
      end
      policy_managed_names = defined?(SyrusMcp::CoreToolSet::POLICY_MANAGED_NAMES) ? SyrusMcp::CoreToolSet::POLICY_MANAGED_NAMES : []

      definitions.reject { |defn| policy_managed_names.include?(defn[:name]) }.map do |defn|
        MCP::Tool.define(
          name: defn[:name],
          description: defn[:description],
          input_schema: defn[:input_schema]
        ) do |server_context:, **params|
          PerformanceLogging.plugin_call(extension_point: :mcp_tool_set, provider: tool_set_class, operation: "handle.#{defn[:name]}") do
            tool_set_class.new.handle(defn[:name], params, server_context)
          end
        end
      end
    end

    def self.authorize_tool(tool)
      tool.extend(Tools::AuthorizationSupport) unless tool.singleton_class < Tools::AuthorizationSupport
      tool.singleton_class.prepend(Tools::AuthorizationSupport::ToolDispatch) unless tool.singleton_class < Tools::AuthorizationSupport::ToolDispatch
      tool
    end

    def self.wrap_stdio_tool_dispatch(tool)
      tool.singleton_class.prepend(StdioToolDispatch) unless tool.singleton_class < StdioToolDispatch
      tool
    end

    def self.record_stdio_tool_exception(tool_name:, server_context:, exception:)
      return if server_context.blank?
      return if server_context.respond_to?(:[]) && server_context[:identity].present?

      backtrace_excerpt = McpToolUsageRecorder.cleaned_backtrace_excerpt(exception)
      content = { message: exception.message }

      Tools.with_database_connection do
        if (chat_session = server_context[:chat_session])
          McpToolUsageRecorder.record_chat_tool_result(
            chat_session: chat_session,
            tool_name: tool_name,
            content: content,
            error: true,
            provider: chat_session.effective_chat_provider,
            sidecar_mode: "stdio",
            error_class: exception.class.name,
            backtrace_excerpt: backtrace_excerpt
          )
        elsif (run = stdio_run_from_context(server_context))
          McpToolUsageRecorder.record_workflow_tool_result(
            run: run,
            tool_name: tool_name,
            content: content,
            error: true,
            sidecar_mode: "stdio",
            error_class: exception.class.name,
            backtrace_excerpt: backtrace_excerpt
          )
        end
      end
    rescue StandardError => record_error
      Rails.logger.warn("[Mcp::Sidecar] stdio tool exception recording failed: #{record_error.class}: #{record_error.message}")
    end

    def self.stdio_run_from_context(server_context)
      run = server_context[:run]
      return run if run

      run_id = server_context[:run_id] || server_context["run_id"]
      Run.find_by(id: run_id) if run_id.present?
    end
    private_class_method :stdio_run_from_context

    def self.chat_context(chat_session, current_message_id:, evaluator: false, scoped_event_id: nil, evaluator_session_id: nil)
      current_message = if current_message_id.present?
        chat_session.messages.find_by(id: current_message_id)
      else
        Tools::CurrentMessage.new(chat_session)
      end

      {
        chat_session: chat_session,
        current_message: current_message,
        evaluator: evaluator ? true : nil,
        scoped_event_id: scoped_event_id.presence,
        evaluator_session_id: evaluator_session_id.presence
      }.compact
    end

    def initialize(server_name:, tools:, server_context:)
      @server_name = server_name
      @tools = tools
      @server_context = server_context
    end

    def build_server
      @sidecar_phase = "build"
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      context = safe_server_context
      @built_server_context = context
      log_workflow_sidecar_event!(
        context,
        "[mcp_sidecar] build starting server=#{@server_name} pid=#{Process.pid}"
      )
      tools = @tools.call.map { |tool| self.class.wrap_stdio_tool_dispatch(tool) }
      context = @server_context.call
      @built_server_context = context
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      log_workflow_sidecar_event!(
        context,
        "[mcp_sidecar] build server=#{@server_name} pid=#{Process.pid} duration_ms=#{duration_ms} tools=#{tool_names(tools).join(',')}"
      )
      MCP::Server.new(
        name: @server_name,
        tools: tools,
        server_context: context
      )
    rescue SystemExit
      raise
    rescue Exception => e # rubocop:disable Lint/RescueException
      context = safe_server_context
      log_workflow_sidecar_event!(
        context,
        "[mcp_sidecar] build failed server=#{@server_name} pid=#{Process.pid} error=#{e.class}: #{e.message}"
      )
      raise
    end

    def run
      @sidecar_phase = "boot"
      @sidecar_sigterm = false
      @sidecar_sigterm_phase = nil
      transport = nil

      at_exit do
        if @sidecar_sigterm
          log_workflow_sidecar_event!(
            safe_server_context,
            "[mcp_sidecar] terminated server=#{@server_name} pid=#{Process.pid} signal=SIGTERM phase=#{@sidecar_sigterm_phase || @sidecar_phase || 'unknown'}"
          )
        end
        Tools::AgentPreviewRegistry.kill_all
        "SyrusBrowser::SessionRegistry".safe_constantize&.kill_all
      end

      Signal.trap("TERM") do
        @sidecar_sigterm = true
        @sidecar_sigterm_phase = @sidecar_phase
        begin
          transport&.close
        rescue StandardError
          nil
        end
        exit 0
      end

      server = build_server
      transport = MCP::Server::Transports::StdioTransport.new(server)

      @sidecar_phase = "transport"
      log_workflow_sidecar_event!(@built_server_context, "[mcp_sidecar] transport opening server=#{@server_name} pid=#{Process.pid}")
      transport.open
    rescue SystemExit
      raise
    rescue Exception => e # rubocop:disable Lint/RescueException
      log_workflow_sidecar_event!(safe_server_context, "[mcp_sidecar] transport failed server=#{@server_name} pid=#{Process.pid} error=#{e.class}: #{e.message}")
      raise
    end

    def tool_names(tools)
      Array(tools).map { |tool| McpToolRegistry.tool_name_for(tool) }.sort
    end

    def safe_server_context
      @server_context.call
    rescue StandardError
      {}
    end

    def log_workflow_sidecar_event!(context, message)
      return unless @server_name == WORKFLOW_SERVER

      run_id = context.respond_to?(:[]) ? context[:run_id] || context["run_id"] : nil
      return if run_id.blank?

      Tools.with_database_connection do
        if (run = Run.find_by(id: run_id))
          JobLog.append!(run: run, kind: "system", chunk: message)
        end
      end
    rescue StandardError => e
      warn "[#{@server_name}] failed to write sidecar JobLog for run #{run_id || '(unknown)'}: #{e.class}: #{e.message}"
    end
  end
end
