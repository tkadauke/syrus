module PendingActions
  class AdminClearGithubCache < Base
    action_key "admin_clear_github_cache"

    def execute
      Admin::Console::Payload.new(actor: user).clear_github_cache(user_id: nil, source: "chat_mcp")
      nil
    end
  end
end
