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
        granted_capabilities: coworker.grants.pluck(:capability),
        capability_approval_policies: unattended_approval_policies(coworker),
        capability_scopes: coworker.grants.pluck(:capability, :scope).to_h
      }
    end

    def self.unattended_approval_policies(coworker)
      coworker.grants.pluck(:capability, :approval_policy).to_h.transform_values do |policy|
        policy == "confirm" ? "queue" : policy
      end
    end
    private_class_method :unattended_approval_policies
  end
end
