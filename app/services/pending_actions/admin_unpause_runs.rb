module PendingActions
  class AdminUnpauseRuns < Base
    action_key "admin_unpause_runs"

    def execute
      Admin::Console::Payload.new(actor: user).unpause_runs(source: "chat_mcp")
      nil
    end
  end
end
