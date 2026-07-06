module PendingActions
  class AdminPauseRuns < Base
    action_key "admin_pause_runs"

    def execute
      Admin::Console::Payload.new(actor: user).pause_runs(source: "chat_mcp")
      nil
    end
  end
end
