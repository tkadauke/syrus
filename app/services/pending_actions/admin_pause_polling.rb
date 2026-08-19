module PendingActions
  class AdminPausePolling < Base
    action_key "admin_pause_polling"

    def execute
      Admin::Console::Payload.new(actor: user).pause_polling(source: "chat_mcp")
      nil
    end

    def execution_label
      "Pausing polling..."
    end
  end
end
