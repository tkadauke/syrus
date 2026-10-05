require "fileutils"
require "json"
require "securerandom"
require "tempfile"
require "tmpdir"

class ChatEventEvaluator
  DECISIONS = %w[no_op respond act].freeze
  MAX_MESSAGES = 500
  MAX_TRANSCRIPT_BYTES = 1.megabyte
  DEFAULT_TIMEOUT = 5.minutes
  DEFAULT_MAX_TURNS = 4
  MAX_RAW_OUTPUT_BYTES = 8.kilobytes

  MessageSnapshot = Data.define(:id, :role, :content, :created_at, :tool_name, :tool_use_id) do
    def canonical_content_format?
      case role
      when "assistant"
        content.is_a?(Array)
      when "tool_use", "tool_result"
        content.is_a?(Hash) && content.key?("type")
      else
        true
      end
    end
  end

  ContextClone = Data.define(:messages, :capped, :message_cap_applied, :byte_cap_applied,
                             :source_message_count, :cloned_message_count, :bytes)

  class << self
    attr_accessor :runner
  end

  def initialize(event:, chat_session:, runner: self.class.runner || ProviderRunner.new)
    @event = event
    @chat_session = chat_session
    @runner = runner
  end

  def call
    return @event.evaluator_result if @event.evaluator_completed?

    session_id = "chat-eval-#{SecureRandom.uuid}"
    @event.mark_evaluator_running!(session_id: session_id)

    clone = clone_context
    provider = @chat_session.effective_chat_provider
    transcript = transcript_for(provider, session_id, clone.messages)
    result = @runner.call(
      provider: provider,
      chat_session: @chat_session,
      event: @event,
      prompt: prompt_for(clone),
      session_id: session_id,
      transcript_jsonl: transcript,
      timeout: DEFAULT_TIMEOUT,
      max_turns: DEFAULT_MAX_TURNS
    )

    payload = normalize_result_with_repair(
      provider: provider,
      clone: clone,
      transcript: transcript,
      session_id: session_id,
      first_result: result
    )
    @event.record_evaluator_result!(payload)
    payload
  rescue StandardError => e
    if @event&.persisted?
      @event.record_evaluator_failure!("#{e.class}: #{e.message}")
      persist_failure_payload(e)
    end
    raise
  end

  def clone_context
    candidate_records = latest_messages(MAX_MESSAGES + 1)
    message_cap = candidate_records.size > MAX_MESSAGES
    records = message_cap ? candidate_records.last(MAX_MESSAGES) : candidate_records
    source_count = records.size + (message_cap ? 1 : 0)
    snapshots = snapshot_messages(records)
    bytes = transcript_bytes(snapshots)
    byte_cap = false

    if bytes > MAX_TRANSCRIPT_BYTES
      byte_cap = true
      snapshots = cap_message_bytes(snapshots)
      bytes = transcript_bytes(snapshots)
    end

    ContextClone.new(
      messages: snapshots,
      capped: message_cap || byte_cap,
      message_cap_applied: message_cap,
      byte_cap_applied: byte_cap,
      source_message_count: source_count,
      cloned_message_count: snapshots.size,
      bytes: bytes
    )
  end

  private

  # Success-completion kinds (job_implemented, pr_merged, epic_completed,
  # main_recovered) used to be blanket-skipped here with no LLM judgment at
  # all -- a routine success and a success the operator is
  # actively waiting on looked identical, so the operator was never woken for
  # either. There is no longer a deterministic auto-skip by kind: every
  # published chat work event reaches the real judgment path below, which
  # decides per-event whether the chat transcript shows the operator cares
  # about this specific outcome. See Prompts::ChatEventEvaluator for the
  # judgment rules.

  def latest_messages(limit)
    ids = messages_scope.reselect(:id).order(id: :desc).limit(limit).pluck(:id)
    return [] if ids.empty?

    messages_scope.where(id: ids).order(:id).to_a
  end

  def messages_scope
    scope = ChatMessage.where(chat_session_id: @chat_session.id)
    return scope unless mysql_adapter?

    scope.from(Arel.sql("#{ChatMessage.quoted_table_name} FORCE INDEX (index_chat_messages_on_session_id_and_id)"))
  end

  def mysql_adapter?
    ActiveRecord::Base.connection.adapter_name.downcase.include?("mysql")
  end

  def snapshot_messages(records)
    records.map do |message|
      MessageSnapshot.new(
        id: message.id,
        role: message.role,
        content: deep_dup_json(message.content),
        created_at: message.created_at,
        tool_name: message.tool_name,
        tool_use_id: message.tool_use_id
      )
    end
  end

  def cap_message_bytes(messages)
    remaining = MAX_TRANSCRIPT_BYTES
    capped = messages.reverse.map do |message|
      content = capped_content(message, remaining)
      clone = MessageSnapshot.new(
        id: message.id,
        role: message.role,
        content: content,
        created_at: message.created_at,
        tool_name: message.tool_name,
        tool_use_id: message.tool_use_id
      )
      remaining -= message_bytes(clone)
      clone
    end
    capped.reverse
  end

  def capped_content(message, remaining)
    per_message = message.role == "tool_result" ? 4.kilobytes : 16.kilobytes
    limit = [ remaining, per_message ].min
    return omitted_content(message) if limit <= 0

    raw = JSON.generate(message.content)
    return message.content if raw.bytesize <= limit

    truncated = Mcp::Tools.truncate_text(raw, [ limit, 128 ].max)
    {
      "text" => "[truncated for disposable evaluator context]",
      "truncated_json" => truncated.fetch(:text),
      "original_bytes" => truncated.fetch(:bytes)
    }
  end

  def omitted_content(message)
    if message.role == "tool_result" && message.content.is_a?(Hash) && message.content["type"].present?
      message.content.merge("content" => "[omitted due to disposable evaluator transcript byte cap]")
    else
      { "text" => "[omitted due to disposable evaluator transcript byte cap]" }
    end
  end

  def transcript_bytes(messages)
    messages.sum { |message| message_bytes(message) }
  end

  def message_bytes(message)
    JSON.generate(
      role: message.role,
      content: message.content,
      tool_name: message.tool_name,
      tool_use_id: message.tool_use_id
    ).bytesize
  end

  def deep_dup_json(value)
    JSON.parse(JSON.generate(value))
  end

  def transcript_for(provider, session_id, messages)
    klass = ChatSessionRehydrator.for(provider)
    raise ChatProviders::ConfigurationError, "Unknown chat provider: #{provider.inspect}" unless klass

    kwargs = { session_id: session_id, messages: messages }
    kwargs[:cwd] = ChatWorkspace.path_for(@chat_session).to_s if provider == "claude"
    klass.new(@chat_session, **kwargs).call
  end

  def prompt_for(clone)
    Prompts::ChatEventEvaluator.new(
      chat_session: @chat_session,
      scoped_event: @event,
      context_summary: {
        capped: clone.capped,
        message_cap_applied: clone.message_cap_applied,
        byte_cap_applied: clone.byte_cap_applied,
        source_message_count: clone.source_message_count,
        cloned_message_count: clone.cloned_message_count,
        cloned_bytes: clone.bytes
      }
    ).to_s
  end

  def repair_prompt_for(clone, raw_output, error)
    <<~PROMPT
      Your previous scoped event evaluator response was not usable:
      #{error.class}: #{error.message}

      Previous output:
      #{Mcp::Tools.truncate_text(raw_output, 4.kilobytes).fetch(:text)}

      Call submit_scoped_event_decision exactly once with a valid decision.
      If that tool is unavailable, return exactly one strict JSON object matching the original schema and no other text.

      #{prompt_for(clone)}
    PROMPT
  end

  def normalize_result_with_repair(provider:, clone:, transcript:, session_id:, first_result:)
    begin
      normalize_result(first_result, clone)
    rescue JSON::ParserError => first_error
      raw_output = raw_text(first_result)
      repair_result = @runner.call(
        provider: provider,
        chat_session: @chat_session,
        event: @event,
        prompt: repair_prompt_for(clone, raw_output, first_error),
        session_id: session_id,
        transcript_jsonl: transcript,
        timeout: DEFAULT_TIMEOUT,
        max_turns: DEFAULT_MAX_TURNS
      )
      begin
        normalize_result(repair_result, clone)
      rescue JSON::ParserError => second_error
        parse_failure_fallback(second_error, clone)
      end
    end
  end

  def normalize_result(result, clone)
    submitted = submitted_tool_result
    return add_context_clone(submitted, clone) if submitted

    raw = raw_text(result)
    @last_evaluator_raw_output = raw
    parsed = JSON.parse(extract_json(raw))
    normalize_parsed_result(parsed, clone, source: "json_text")
  end

  def raw_text(result)
    result.respond_to?(:final_text) ? result.final_text.to_s : result.to_s
  end

  def submitted_tool_result
    payload = @event.reload.evaluator_result
    return unless payload.is_a?(Hash)
    return unless payload["submitted_via"] == "mcp_tool"
    return unless DECISIONS.include?(payload["decision"].to_s)

    payload
  end

  def normalize_parsed_result(parsed, clone, source:)
    decision = parsed["decision"].to_s
    decision = "no_op" unless DECISIONS.include?(decision)

    add_context_clone({
      "decision" => decision,
      "reason" => parsed["reason"].to_s,
      "urgency" => clamp_float(parsed["urgency"]),
      "confidence" => clamp_float(parsed["confidence"]),
      "handoff_prompt" => parsed["handoff_prompt"].to_s.presence,
      "submitted_via" => source
    }.compact, clone)
  end

  def add_context_clone(payload, clone)
    payload.merge(
      "context_clone" => {
        "capped" => clone.capped,
        "message_cap_applied" => clone.message_cap_applied,
        "byte_cap_applied" => clone.byte_cap_applied,
        "source_message_count" => clone.source_message_count,
        "cloned_message_count" => clone.cloned_message_count,
        "bytes" => clone.bytes
      }
    ).compact
  end

  def extract_json(raw)
    stripped = raw.to_s.strip
    return stripped if stripped.start_with?("{") && stripped.end_with?("}")

    match = stripped.match(/\{.*\}/m)
    raise JSON::ParserError, "evaluator did not return JSON" unless match

    match[0]
  end

  def clamp_float(value)
    numeric = Float(value, exception: false) || 0.0
    [ [ numeric, 0.0 ].max, 1.0 ].min
  end

  def parse_failure_fallback(error, clone)
    return low_severity_parse_fallback(error, clone) if low_severity_informational_event?

    add_context_clone({
      "decision" => "respond",
      "reason" => "Evaluator returned malformed JSON after a repair retry: #{error.message}",
      "urgency" => fallback_urgency,
      "confidence" => 0.0,
      "handoff_prompt" => fallback_handoff_prompt(error),
      "submitted_via" => "parse_failure_fallback"
    }, clone)
  end

  def low_severity_parse_fallback(error, clone)
    add_context_clone({
      "decision" => "no_op",
      "reason" => "Evaluator returned malformed JSON for a low-severity informational event: #{error.message}",
      "urgency" => 0.0,
      "confidence" => 0.0,
      "submitted_via" => "low_severity_parse_fallback"
    }, clone)
  end

  def low_severity_informational_event?
    severity = @event.payload["severity"].to_s.downcase
    return false if %w[critical error warning high].include?(severity)

    kind = [ @event.source_kind, @event.payload["kind"], @event.payload["event"] ].compact.join(" ").downcase
    return false if kind.match?(/fail|error|degraded|stuck|blocked|attention|limit|quota/)

    severity.blank? || %w[info informational low].include?(severity)
  end

  def fallback_urgency
    severity = @event.payload["severity"].to_s.downcase
    return 1.0 if %w[critical high].include?(severity)
    return 0.7 if %w[error warning].include?(severity)

    0.4
  end

  def fallback_handoff_prompt(error)
    summary = @event.payload["summary"].to_s.presence ||
      @event.payload["title"].to_s.presence ||
      @event.payload["message"].to_s.presence ||
      @event.source_kind.to_s

    <<~PROMPT.strip
      A scoped event evaluator could not produce parseable JSON after a repair retry.
      Treat this as an evaluator failure, not as proof that the underlying event is actionable.

      Event kind: #{@event.source_kind}
      Event summary: #{summary}
      Evaluator parse error: #{error.class}: #{error.message}

      Read current Syrus state before deciding whether any action is required.
    PROMPT
  end

  def persist_failure_payload(error)
    raw = @last_evaluator_raw_output.to_s
    @event.update!(
      evaluator_result: {
        "failure" => {
          "error" => "#{error.class}: #{error.message}",
          "raw_output" => Mcp::Tools.truncate_text(raw, MAX_RAW_OUTPUT_BYTES),
          "captured_at" => Time.current.iso8601
        }
      }
    )
  end

  class ProviderRunner
    SIDECAR_ENV_FORWARD = AgentProviders::Base::SIDECAR_ENV_FORWARD

    def call(provider:, chat_session:, event:, prompt:, session_id:, transcript_jsonl:, timeout:, max_turns:)
      Dir.mktmpdir("syrus-chat-event-evaluator") do |workspace_path|
        with_evaluator_mcp_config(chat_session, event: event, session_id: session_id) do |mcp_config|
          provider_class = ChatProviders.for(provider)
          unless provider_class.respond_to?(:invoke_event_evaluator)
            raise ChatProviders::ConfigurationError, "#{provider.inspect} does not support scoped event evaluation"
          end

          provider_class.invoke_event_evaluator(
            chat_session: chat_session,
            workspace_path: workspace_path,
            prompt: prompt,
            session_id: session_id,
            transcript_jsonl: transcript_jsonl,
            mcp_config: mcp_config,
            timeout: timeout,
            max_turns: max_turns,
            runner: ChatTurnJob.agent_runner
          )
        end
      end
    end

    private

    SERVER_NAME = "syrus-chat-evaluator-sidecar".freeze

    def with_evaluator_mcp_config(chat_session, event:, session_id:)
      Tempfile.create([ "syrus-chat-evaluator-mcp-#{chat_session.id}-", ".json" ]) do |file|
        file.write({
          mcpServers: {
            SERVER_NAME => evaluator_server_config(chat_session, event: event, session_id: session_id)
          }
        }.to_json)
        file.flush
        yield file.path
      end
    end

    # The evaluator reaches its tools the same way the essential and deferred
    # chat servers do: through bin/syrus-mcp-proxy, a secret-free bridge to a
    # worker-owned daemon.
    #
    # It used to spawn bin/syrus-chat-sidecar directly, which boots Rails. The
    # agent-visible config is built with AgentSidecarEnvironment.build, which
    # withholds SECRET_KEY_BASE and the database credentials on purpose -- the
    # config file is readable by the agent -- so that process could not boot at
    # all ("Missing `secret_key_base` for 'production' environment"). Every
    # evaluator run failed, and because Muse fails a run when a required server
    # fails to start, the failure was fatal there rather than silent.
    def evaluator_server_config(chat_session, event:, session_id:)
      decision = ChatMcpTransportSelector.select
      endpoint = evaluator_endpoint(decision)

      {
        type: "stdio",
        command: Rails.root.join("bin/syrus-mcp-proxy").to_s,
        args: [],
        env: evaluator_proxy_env(chat_session, endpoint: endpoint, event: event, session_id: session_id),
        alwaysLoad: true
      }
    rescue StandardError => e
      Rails.logger.warn(
        "[ChatEventEvaluator] evaluator MCP proxy unavailable for chat ##{chat_session.id}: #{e.class}: #{e.message}"
      )
      unavailable_server_config
    end

    # Both the persistent daemon and the stdio compatibility daemon expose the
    # same HTTP endpoint and mint tokens against their own worker identity, so
    # the proxy does not care which one answers.
    def evaluator_endpoint(decision)
      if decision&.persistent?
        Endpoint.new(
          url: "http://#{PersistentMcpDaemon.host}:#{PersistentMcpDaemon.port}#{PersistentMcpDaemon::MCP_PATH}",
          worker_id: decision.daemon_identity["worker_id"]
        )
      else
        fallback = ChatMcpStdioFallback.server
        Endpoint.new(url: fallback.url, worker_id: fallback.identity.fetch(:worker_id))
      end
    end

    Endpoint = Data.define(:url, :worker_id)

    def evaluator_proxy_env(chat_session, endpoint:, event:, session_id:)
      AgentSidecarEnvironment.build(extra: {
        "SYRUS_MCP_PROXY_URL" => endpoint.url,
        "SYRUS_MCP_PROXY_INVOCATION_CONTEXT" => evaluator_invocation_token(
          chat_session, endpoint: endpoint, event: event, session_id: session_id
        ),
        "PATH" => ENV["PATH"]
      }.compact)
    end

    # `current_message` is deliberately omitted: an evaluator run is scoped to
    # an event, not to a chat turn, so turn-active validation must not apply to
    # it. `evaluator: true` is what resolves the token to
    # AgentRole::CHAT_EVALUATOR and therefore to the evaluator tool surface.
    def evaluator_invocation_token(chat_session, endpoint:, event:, session_id:)
      McpInvocationContext.issue_for_chat(
        chat_session,
        worker_id: endpoint.worker_id,
        tier: "evaluator",
        evaluator: true,
        scoped_event_id: event.id,
        evaluator_session_id: session_id,
        provider: chat_session.effective_chat_provider,
        expires_in: AgentInvocation::DEFAULT_TIMEOUT_SECONDS.seconds
      )
    end

    # Secret-free refusal responder, the same one chat turns fall back to. It
    # answers the handshake and declines every call, which beats a server that
    # cannot start: a required server that fails startup kills the whole run.
    def unavailable_server_config
      {
        type: "stdio",
        command: Rails.root.join("bin/syrus-mcp-unavailable").to_s,
        args: [],
        env: AgentSidecarEnvironment.build(extra: {
          "SYRUS_MCP_UNAVAILABLE_SERVER_NAME" => SERVER_NAME,
          "SYRUS_MCP_UNAVAILABLE_MESSAGE" => "Chat evaluator MCP tools are unavailable because no MCP daemon could be reached for this run.",
          "PATH" => ENV["PATH"]
        }.compact),
        alwaysLoad: true
      }
    end
  end
end
