module RepositoryTabsSerialization
  extend ActiveSupport::Concern

  private

  def repository_tabs_json(repository)
    Repositories::PluginRepoTabsPayload.tabs_for(repository: repository, user: Current.user).map do |tab|
      { key: tab[:key], label: tab[:label], path: tab[:path], badge: tab[:badge] }.compact
    end
  end
end
