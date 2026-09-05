module RepositoryTabsSerialization
  extend ActiveSupport::Concern

  private

  def repository_tabs_json(repository)
    tabs = [
      { key: "overview", label: "Overview", path: repository_path(repository) },
      { key: "documents", label: "Documents", path: repository_documents_path(repository) },
      { key: "members", label: "Members", path: repository_memberships_path(repository) }
    ]
    tabs.concat(
      Repositories::PluginRepoTabsPayload.tabs_for(repository: repository, user: Current.user).map do |tab|
        { key: tab[:id], label: tab[:label], path: tab[:path], badge: tab[:badge] }
      end
    )
    tabs
  end
end
