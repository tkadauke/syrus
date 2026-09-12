module AgentActivity
  class DesignDocSessionContext < SessionContext
    def kind = "design_doc"
    def role = AgentRole::CHAT_PLANNER
    def role_label = "Design Doc"
    def agent_provider = @resumable.agent_provider
    def state = @resumable.status == "canceled" ? "cancelled" : @resumable.status

    def outcome_summary
      "#{design_doc.display_id} #{design_doc.title}"
    end

    def repository_payload
      repository = design_doc.repositories.first
      return nil unless repository

      {
        id: repository.id,
        slug: "#{repository.owner}/#{repository.name}"
      }
    end

    private

    def design_doc
      @design_doc ||= @resumable.design_doc
    end
  end
end
