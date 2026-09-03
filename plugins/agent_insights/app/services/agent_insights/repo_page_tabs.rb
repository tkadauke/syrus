module AgentInsights
  class RepoPageTabs
    include Syrus::Plugin::RepoPageTab

    def self.repo_page_tabs(repository:, user:)
      return [] if repository.blank?

      pending = Suggestion.where(repository_id: repository.id, state: "pending").count

      [
        {
          id: "agent_insights.repository",
          label: "Insights",
          label_key: "agent_insights:tab_insights",
          path: "/repositories/#{repository.id}/plugin/insights",
          paths: [ "/repositories/#{repository.id}/plugin/insights" ],
          component: "agent_insights/RepositoryInsights",
          order: 5,
          badge: pending.positive? ? pending : nil
        }.compact
      ]
    end
  end
end
