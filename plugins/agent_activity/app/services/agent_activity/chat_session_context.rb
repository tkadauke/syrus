module AgentActivity
  class ChatSessionContext < SessionContext
    ROLE_BY_MODE = {
      "planning" => AgentRole::CHAT_PLANNER,
      "coding" => AgentRole::CHAT_CODING,
      "local" => AgentRole::CHAT_LOCAL
    }.freeze

    def kind = @resumable.mode || "chat"
    def role = ROLE_BY_MODE.fetch(@resumable.mode, AgentRole::CHAT_PLANNER)
    def role_label = @resumable.mode&.humanize || "Chat"
    def agent_provider = @resumable.chat_provider
    def chat_path = "/chats/#{@resumable.id}"

    def repository_payload
      repository = @resumable.repository
      return nil unless repository

      {
        id: repository.id,
        slug: "#{repository.owner}/#{repository.name}"
      }
    end
  end
end
