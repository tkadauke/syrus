module Repositories
  # Per-repo/per-user analogue of Admin::PluginPagesPayload: unlike admin
  # pages (instance-wide), a repo-page-tab provider computes visibility
  # per repository/user via .repo_page_tabs(repository:, user:).
  class PluginRepoTabsPayload
    # Shared with RepositoryTabsSerialization#repository_tabs_json, which
    # needs the same normalized descriptors (in the plain key/label/path/badge
    # shape the tab bar renders) alongside the hardcoded tabs.
    def self.tabs_for(repository:, user:)
      Syrus::PluginRegistry.providers_for(:repo_page_tab)
        .flat_map { |provider| tabs_from_provider(provider, repository: repository, user: user) }
        .sort_by { |tab| [ tab[:order].to_i, tab[:label].to_s ] }
    end

    def self.tabs_from_provider(provider, repository:, user:)
      PerformanceLogging.plugin_call(extension_point: :repo_page_tab, provider: provider, operation: :repo_page_tabs) do
        Array(provider.repo_page_tabs(repository: repository, user: user)).map { |tab| tab_payload(tab) }
      end
    end

    def self.tab_payload(tab)
      tab = tab.to_h.symbolize_keys
      {
        id: tab.fetch(:id).to_s,
        label: tab.fetch(:label).to_s,
        label_key: tab[:label_key].presence&.to_s,
        path: tab.fetch(:path).to_s,
        paths: Array(tab[:paths].presence || tab[:path]).map(&:to_s),
        component: tab[:component].presence&.to_s,
        order: tab[:order].to_i,
        badge: tab[:badge]
      }
    end

    def initialize(repository:, user:)
      @repository = repository
      @user = user
    end

    def as_json(*)
      { tabs: self.class.tabs_for(repository: @repository, user: @user) }
    end
  end
end
