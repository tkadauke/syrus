module RepositoryTabsSerialization
  extend ActiveSupport::Concern

  private

  def repository_tabs_json(repository)
    health_tab = { key: "health", label: "Health", path: "/repositories/#{repository.id}/health" }
    health_tab[:badge] = "!" if repository.main_health_broken?

    tabs = [
      { key: "overview", label: "Overview", path: repository_path(repository) },
      health_tab,
      { key: "target_graph", label: "Target Graph", path: "/repositories/#{repository.id}/target_graph" },
      { key: "documents", label: "Documents", path: repository_documents_path(repository) }
    ]
    tabs.concat(
      Repositories::PluginRepoTabsPayload.tabs_for(repository: repository, user: Current.user).map do |tab|
        { key: tab[:id], label: tab[:label], path: tab[:path], badge: tab[:badge] }
      end
    )
    tabs
  end
end
