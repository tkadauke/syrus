module Coworkers
  class RunContextContributor
    include Syrus::Plugin::McpRunContextContributor

    def self.context_attributes(run:, role:)
      return {} unless role == AgentRole::COWORKER && run.job.origin == "coworkers"

      coworker = Coworkers::Coworker.find_by(id: run.job.origin_id)
      return {} unless coworker

      main_chat = coworker.coworker_chats.find_by(role: "main")&.chat_session
      {
        chat_session: main_chat,
        allowed_memory_scopes: %w[ global repository instance ],
        allowed_chat_session_ids: coworker.readable_chat_session_ids,
        granted_capabilities: Coworkers::PrivilegedGrantGate.allowed_capabilities(coworker),
        capability_scopes: capability_scopes(coworker),
        agent_actor: coworker
      }
    end

    def self.capability_scopes(coworker)
      allowed = Coworkers::PrivilegedGrantGate.allowed_capabilities(coworker)
      coworker.grants.where(capability: allowed).pluck(:capability, :scope).to_h
    end
    private_class_method :capability_scopes
  end
end
