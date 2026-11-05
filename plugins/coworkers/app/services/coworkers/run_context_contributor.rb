module Coworkers
  class RunContextContributor
    include Syrus::Plugin::McpRunContextContributor

    def self.context_attributes(run:, role:)
      target = run.step.details.to_h["reviewer_target"]
      if target.present?
        coworker = Coworkers::Coworker.find_by(id: target["record_id"])
        return reviewer_context(coworker, run) if coworker
      end
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

    def self.reviewer_context(coworker, run)
      raise ArgumentError, "coworker reviewer is not active" unless coworker.state == "active"
      raise ArgumentError, "coworker reviewer owner does not match the Job owner" unless coworker.owner_user_id == run.job.effective_owner_id
      scope = capability_scopes(coworker)
      raise ArgumentError, "coworker reviewer is not authorized for this repository" unless Array(scope["code.read"]).map(&:to_i).include?(run.job.repository_id)

      { granted_capabilities: [ "code.read" ], capability_scopes: { "code.read" => [ run.job.repository_id ] }, agent_actor: coworker }
    end

    def self.capability_scopes(coworker)
      allowed = Coworkers::PrivilegedGrantGate.allowed_capabilities(coworker)
      coworker.permission_rules.entries.filter_map do |entry|
        [ entry[:capability], entry[:scope] ] if allowed.include?(entry[:capability])
      end.to_h
    end
    private_class_method :capability_scopes
  end
end
