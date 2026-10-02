module AgentInsights
  class SlugType
    include Syrus::Plugin::SlugType

    def self.prefix = "INSIGHT"
    def self.display_label = "Insight"
    def self.preview_available? = true
    def self.page_size = 20

    def self.client_path(id)
      "/s/#{canonical_slug(id)}"
    end

    def self.record_for(id, user:)
      return nil unless user

      AgentInsights::Suggestion
        .joins(:repository)
        .where(repositories: { id: Repository.accessible_to(user).select(:id) })
        .find_by(id: id)
    end

    def self.web_path(record)
      "/repositories/#{record.repository_id}/plugin/insights?state=all&page=#{page_for(record)}##{canonical_slug(record.id)}"
    end

    def self.api_preview_path(record)
      "/api/v1/app/insight_suggestions/#{record.id}/preview"
    end

    def self.page_for(record)
      index = AgentInsights::Suggestion
        .for_repository(record.repository)
        .display_order
        .pluck(:id)
        .index(record.id)

      return 1 unless index

      (index / page_size) + 1
    end
  end
end
