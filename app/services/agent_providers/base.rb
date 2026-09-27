require "tmpdir"

module AgentProviders
  class Base
    SessionCapture = Data.define(:provider, :session_id, :transcript_jsonl, :missing_message)

    SIDECAR_ENV_FORWARD = AgentSidecarEnvironment::SAFE_ENV_FORWARD

    def initialize(run:, workspace:, parent_session_id:)
      @run = run
      @workspace = workspace
      @parent_session_id = parent_session_id
      @workflow = run.step.workflow
      @job = workflow.job
    end

    def self.provider
      name.to_s.demodulize.underscore.presence || "unknown"
    end

    def self.provider_key
      provider
    end

    # Refreshes this provider's cached usage snapshot when it looks stale.
    # Providers with no usage probe (the default) do nothing.
    def self.refresh_stale_usage!(user:, now: Time.current)
    end

    def self.refresh_usage!(user:, force: false)
    end

    def self.mcp_tool_name(tool_name, server_name:)
    end

    def self.available_models
      []
    end

    def self.evidence_reset_at(evidence)
    end

    def self.false_positive_evidence?(evidence)
      false
    end

    def self.suppress_usage_limit_run?(_run, model:, observed_at:)
      false
    end

    def self.ignore_model_for_positive_evidence?(model)
      false
    end

    def self.usage_signal_account_id(_user)
    end

    def self.usage_snapshot(user:, evidence:)
      evidence&.details&.dig("snapshot") || {}
    end

    def self.usage_status(user:, evidence:)
      evidence&.status
    end

    def self.usage_observed_at(user:, evidence:)
      evidence&.observed_at&.iso8601
    end

    def self.availability_evidence_observed_at(user:, latest_evidence:)
      latest_evidence&.observed_at
    end

    def self.usage_windows(snapshot, observed_at:, now:)
      [ snapshot["primary"], snapshot["secondary"] ].compact.each_with_object({}) do |window, memo|
        label = window["label"].to_s
        key = case label
        when "5h" then "five_hour"
        when "weekly" then "weekly"
        else next
        end
        memo[key] = {
          label: label,
          remaining_percent: window["remaining_percent"],
          used_percent: window["used_percent"],
          reset_at: window["reset_at"]
        }.compact
      end
    end

    def provider
      self.class.provider
    end

    def run(prompt:, log_sink:, max_turns: nil, required_mcp_tools: nil, disallowed_tools: nil,
           model: nil, effort_level: nil)
      invoke(
        workspace_path: workspace.path,
        prompt: prompt,
        log_sink: log_sink,
        timeout: invocation_timeout,
        max_turns: max_turns || default_max_turns,
        mcp: true,
        resume_session_id: parent_session_id,
        required_mcp_tools: required_mcp_tools,
        disallowed_tools: disallowed_tools,
        model: model,
        effort_level: effort_level
      )
    end

    def run_once(prompt:, log_sink:, timeout:, max_turns:)
      Dir.mktmpdir("syrus-agent-once") do |tmpdir|
        invoke(
          workspace_path: tmpdir,
          prompt: prompt,
          log_sink: log_sink,
          timeout: timeout,
          max_turns: max_turns,
          mcp: false,
          resume_session_id: nil
        )
      end
    end

    def record_result!(result, log:)
      updates = {}
      updates[:agent_turns] = result.turns if result.turns
      updates[:agent_outcome] = result.outcome if result.outcome
      updates[:cost_usd] = result.cost_usd if result.cost_usd
      updates[:input_tokens] = result.input_tokens if result.input_tokens
      updates[:output_tokens] = result.output_tokens if result.output_tokens
      updates[:cache_creation_input_tokens] = result.cache_creation_input_tokens if result.cache_creation_input_tokens
      updates[:cache_read_input_tokens] = result.cache_read_input_tokens if result.cache_read_input_tokens
      @run.update!(updates) if updates.any?

      SessionStore.new(run: @run, log: log).capture!(session_capture(result))
      result
    end

    def session_capture(result)
      return nil if result.session_id.blank?

      SessionCapture.new(
        provider: provider,
        session_id: result.session_id,
        transcript_jsonl: transcript_from_result(result),
        missing_message: nil
      )
    end

    private

    attr_reader :workspace, :parent_session_id, :workflow, :job

    def invoke(workspace_path:, prompt:, log_sink:, timeout:, max_turns:, mcp:, resume_session_id:,
              required_mcp_tools: nil, disallowed_tools: nil, model: nil, effort_level: nil)
      raise NotImplementedError, "#{self.class.name} must implement #invoke"
    end

    def invocation_timeout
      AgentInvocation::DEFAULT_TIMEOUT_SECONDS
    end

    def default_max_turns
      job.user.agent_max_turns
    end

    def transcript_from_result(result)
      return result.transcript_jsonl if result.transcript_jsonl.present?
      return nil if result.transcript_path.blank? || !File.exist?(result.transcript_path)

      File.read(result.transcript_path)
    end

    def sidecar_env
      AgentSidecarEnvironment.build_boot
    end

    def sidecar_command
      Rails.root.join("bin/syrus-mcp-sidecar").to_s
    end

    def sidecar_args
      [ "--run-id", @run.id.to_s ]
    end

    def stdio_mcp_server_config(decision = effective_stdio_mcp_transport_decision)
      if decision&.persistent?
        {
          command: Rails.root.join("bin/syrus-mcp-proxy").to_s,
          args: [],
          env: persistent_proxy_env(decision)
        }
      else
        {
          command: sidecar_command,
          args: sidecar_args,
          env: sidecar_env
        }
      end
    end

    def effective_stdio_mcp_transport_decision
      mcp_transport_decision
    end

    def persistent_proxy_env(decision)
      {
        "SYRUS_MCP_PROXY_URL" => persistent_mcp_url,
        "SYRUS_MCP_PROXY_INVOCATION_CONTEXT" => mint_invocation_context_token(decision),
        "PATH" => ENV["PATH"]
      }.compact
    end

    def persistent_mcp_url
      "http://#{PersistentMcpDaemon.host}:#{PersistentMcpDaemon.port}#{PersistentMcpDaemon::MCP_PATH}"
    end

    def mint_invocation_context_token(decision)
      McpInvocationContext.issue_for_run(
        @run,
        worker_id: decision.daemon_identity.fetch("worker_id"),
        provider: provider
      )
    end

    # Memoized per invocation. `nil` when the feature is off, which callers
    # use as the "behave exactly as before, don't log anything" signal --
    # see #log_mcp_transport_decision!.
    def mcp_transport_decision
      return @mcp_transport_decision if defined?(@mcp_transport_decision)

      role = AgentRole.for_step_kind(@run.step.kind)
      @mcp_transport_decision = Feature.persistent_mcp_sidecar_enabled? ? WorkflowMcpTransportSelector.select(role: role) : nil
    end

    # Records the transport decision where existing run/job diagnostics
    # already surface it: a JobLog system line (transcript) and
    # Step#details (already serialized by Admin::JobStateSerializer, so no
    # separate diagnostics plumbing is needed). No-ops (and is never called)
    # when the feature is off, so disabled behavior stays byte-identical to
    # before this existed.
    def log_mcp_transport_decision!(decision)
      return unless decision

      step = @run.step
      step.update!(details: (step.details || {}).merge(
        "mcp_transport" => {
          "transport" => decision.transport.to_s,
          "reason" => decision.reason,
          "checked_at" => Time.current.utc.iso8601
        }.compact
      ))

      message = if decision.persistent?
        "[mcp_transport] transport=persistent daemon_worker_id=#{decision.daemon_identity&.dig('worker_id')}"
      else
        "[mcp_transport] transport=stdio reason=#{decision.reason}"
      end
      JobLog.append!(run: @run, kind: "system", chunk: message)
    rescue StandardError => e
      Rails.logger.warn("[#{self.class.name}] failed to record mcp transport decision: #{e.class}: #{e.message}")
    end
  end
end
