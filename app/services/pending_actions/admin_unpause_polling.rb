module PendingActions
  class AdminUnpausePolling < Base
    action_key "admin_unpause_polling"

    def execute
      Admin::Console::Payload.new(actor: user).unpause_polling(source: "chat_mcp")
      nil
    end
  end
end
