module ChatShellCommandExecutor
  # Runs a `!` shell command against a chat session's checkout (EPIC-323).
  # `ChatSession#mode` picks the concrete strategy: Coding Mode runs directly
  # on the worker's persistent ChatWorkspace via ProcessRunner; Local Mode has
  # no Syrus-side checkout and dispatches over the reverse tunnel the Local
  # Mode agent's `run_command` tool already uses (Mcp::Tools::LocalToolDispatch).
  class Base
    Result = Struct.new(:outcome, :output, :exit_status, keyword_init: true)

    def self.for(mode)
      { "coding" => Coding, "local" => Local }.fetch(mode.to_s) {
        raise ArgumentError, "no shell command executor for chat mode #{mode.inspect}"
      }.new
    end

    def feature_enabled?
      raise NotImplementedError
    end

    # Returns an error message when the chat session isn't ready to run a
    # `!` command yet, or nil when it is.
    def precondition_error(chat_session)
      raise NotImplementedError
    end

    # Blocks the calling job until the command finishes, is cancelled, or
    # times out, and returns a Result.
    def run!(command_record)
      raise NotImplementedError
    end

    def cancellable?(command_record)
      raise NotImplementedError
    end

    def request_cancel!(command_record, user:)
      raise NotImplementedError
    end
  end
end
