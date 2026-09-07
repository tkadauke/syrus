module ChatShellCommandExecutor
  # Local Mode `!` commands have no Syrus-side checkout, so they dispatch
  # over the same reverse WebSocket tunnel the Local Mode agent's
  # `run_command` MCP tool uses (Mcp::Tools::LocalToolDispatch / LocalTunnelChannel),
  # running against the operator's own machine and checkout.
  class Local < Base
    DISCONNECTED_ERROR = "Local daemon not connected. Run `syrus local` in your repo to continue.".freeze

    def feature_enabled?
      Feature.local_mode_enabled?
    end

    def precondition_error(chat_session)
      return DISCONNECTED_ERROR unless daemon_actually_connected?(chat_session)

      nil
    end

    def run!(command_record)
      chat_session = command_record.chat_session
      session = chat_session.local_daemon_session
      return Result.new(outcome: "error", output: DISCONNECTED_ERROR) unless daemon_actually_connected?(chat_session)

      tool_call = session.dispatch_tool_call!("run_command", { command: command_record.command })
      command_record.update_columns(local_tool_call_id: tool_call.id)

      outcome = tool_call.wait_for_result(timeout: ChatShellCommandJob::MAX_RUNTIME_SECONDS)
      interpret(tool_call, outcome)
    rescue LocalToolCall::TimedOut
      Result.new(outcome: "error", output: "Local daemon command timed out with no response.")
    end

    def cancellable?(command_record)
      command_record.local_tool_call.present? && command_record.local_tool_call.state == "dispatched"
    end

    def request_cancel!(command_record, user:)
      command_record.local_tool_call&.request_cancel!
    end

    private

    # `LocalDaemonSession#connected?` (`disconnected_at.nil?`) is true from the
    # moment `LocalDaemonSessionsController#create` mints the row to hand the
    # operator a connect token -- well before the daemon has actually dialed
    # in. `ChatSession#daemon_connected?` is the flag `mark_connected!` /
    # `mark_disconnected!` flip on the real "connect" handshake over
    # LocalTunnelChannel (the same signal the "not connected" banner reads),
    # so gate on that instead of the session row's mere existence.
    def daemon_actually_connected?(chat_session)
      chat_session.daemon_connected? && chat_session.local_daemon_session&.connected?
    end

    # `outcome` is the daemon's raw run_command result hash
    # (executeLocalRunCommand in cli/cmd/local.go): { stdout:, stderr:,
    # exit_code:, killed: }, or nil when the LocalToolCall itself failed
    # (daemon error, or disconnected before responding — see
    # LocalDaemonSession#mark_disconnected!).
    def interpret(tool_call, outcome)
      if outcome.nil?
        Result.new(outcome: "error", output: tool_call.reload.error.presence || "Local daemon command failed.")
      elsif outcome["error"].present?
        Result.new(outcome: "error", output: outcome["error"].to_s)
      elsif outcome["killed"]
        Result.new(outcome: "killed", output: combined_output(outcome), exit_status: outcome["exit_code"])
      else
        exit_status = outcome["exit_code"]
        Result.new(outcome: exit_status == 0 ? "succeeded" : "failed", output: combined_output(outcome), exit_status: exit_status)
      end
    end

    def combined_output(outcome)
      [ outcome["stdout"], outcome["stderr"] ].compact_blank.join
    end
  end
end
