require "json"

module ChatProviders
  class Muse < Base
    include Syrus::Plugin::ChatProvider

    def self.provider_key = "muse"
    def self.display_name = "Muse Code"
    def self.available? = true

    def self.provider = provider_key

    def self.invoke_event_evaluator(chat_session:, workspace_path:, prompt:, session_id:, transcript_jsonl:, mcp_config:, timeout:, max_turns:, runner:)
      MuseInvocation.new(
        workspace_path,
        prompt: prompt_with_transcript_context(prompt, transcript_jsonl),
        api_key: chat_session.user.muse_api_key,
        log_sink: ->(*) { },
        runner: runner,
        timeout: timeout,
        session_id: session_id,
        max_model_steps: max_turns,
        transcript_policy: :exec_jsonl,
        muse_home: ChatWorkspace.agent_home_for(chat_session, "muse"),
        mcp_server: mcp_server_for(mcp_config)
      ).run
    end

    def credentials_missing?
      !chat.user.chat_provider_configured?(provider)
    end

    def credentials_missing_message
      "Muse credentials are missing. Add a Muse API key in Credentials, then send another message."
    end

    def invoke(workspace_path:, prompt:, log_sink:, mcp_config:, resume_session_id:,
               stop_requested:, process_started:)
      result = run_invocation(
        workspace_path: workspace_path,
        prompt: prompt,
        log_sink: log_sink,
        mcp_config: mcp_config,
        resume_session_id: resume_session_id,
        stop_requested: stop_requested,
        process_started: process_started
      )

      if resume_session_id.present? && stale_resume_failure?(result)
        log_sink.call(
          "The previous Muse chat session was unavailable, so Syrus is continuing from recent history.",
          kind: "system"
        )
        result = run_invocation(
          workspace_path: workspace_path,
          prompt: prompt_with_system(prompt),
          log_sink: log_sink,
          mcp_config: mcp_config,
          resume_session_id: nil,
          stop_requested: stop_requested,
          process_started: process_started
        )
      end

      result
    end

    def session_capture(result)
      capture = super
      return nil unless capture
      return capture if capture.transcript_jsonl.present?

      SessionCapture.new(
        provider: provider,
        session_id: result.session_id,
        transcript_jsonl: nil,
        normalized_messages: [],
        missing_message: "[chat_session] Muse transcript capture was empty - session continuation won't be available for this chat"
      )
    end

    private

    def run_invocation(workspace_path:, prompt:, log_sink:, mcp_config:, resume_session_id:,
                       stop_requested:, process_started:)
      MuseInvocation.new(
        workspace_path,
        prompt: prompt,
        api_key: chat.user.reload.muse_api_key,
        log_sink: log_sink,
        runner: runner,
        session_id: resume_session_id,
        model: chat.chat_model.presence,
        reasoning_effort: chat.chat_effort,
        transcript_policy: :exec_jsonl,
        muse_home: ChatWorkspace.agent_home_for(chat, provider),
        mcp_server: self.class.mcp_server_for(mcp_config),
        stop_requested: stop_requested,
        process_started: process_started
      ).run
    end

    def stale_resume_failure?(result)
      return false unless result
      return false unless result.is_error && result.turns.to_i.zero?

      [ result.outcome, result.final_text ].compact.join(" ").match?(/session|conversation|resume/i) &&
        [ result.outcome, result.final_text ].compact.join(" ").match?(/not found|missing|unavailable|expired|stale/i)
    end

    def prompt_with_system(prompt)
      system = Prompts::ChatSystem.new(repository: chat.repository, chat_session: chat).to_s
      "#{system}\n\n---\n\n#{prompt}"
    end

    def self.mcp_server_for(path)
      raw = JSON.parse(File.read(path))
      raw.fetch("mcpServers").transform_values do |server|
        {
          command: server.fetch("command"),
          args: Array(server["args"]),
          env: server.fetch("env", {})
        }
      end
    end

    def self.prompt_with_transcript_context(prompt, transcript_jsonl)
      context = transcript_context(transcript_jsonl)
      return prompt if context.blank?

      <<~PROMPT
        Prior chat context for this disposable Muse evaluator session:

        #{context}

        ---

        #{prompt}
      PROMPT
    end

    def self.transcript_context(transcript_jsonl)
      ClaudeTranscript.new(transcript_jsonl).events.filter_map do |event|
        case event.kind
        when :user_prompt
          "user: #{event.data.fetch(:text)}"
        when :assistant_text
          "assistant: #{event.data.fetch(:text)}"
        when :tool_use
          "tool_use: #{event.data[:name]} #{event.data[:input].to_json}"
        when :tool_result
          "tool_result: #{event.data[:name] || event.data[:tool_use_id]} #{event.data[:content].to_json}"
        end
      end.join("\n")
    end
  end
end
