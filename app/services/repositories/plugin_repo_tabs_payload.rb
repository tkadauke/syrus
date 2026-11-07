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
      { tabs: core_tabs + plugin_tabs }
    end

    private

    def core_tabs
      health_tab = tab(id: "health", label: "Health", path: "/repositories/#{@repository.id}/health", order: 10)
      health_tab[:badge] = "!" if @repository.main_health_broken?

      [
        tab(id: "overview", label: "Overview", path: Rails.application.routes.url_helpers.repository_path(@repository), order: 0),
        health_tab,
        tab(id: "cognitive_debt", label: "Cognitive Debt", path: "/repositories/#{@repository.id}/cognitive_debt", order: 20),
        tab(id: "target_graph", label: "Target Graph", path: "/repositories/#{@repository.id}/target_graph", order: 30),
        tab(id: "documents", label: "Documents", path: Rails.application.routes.url_helpers.repository_documents_path(@repository), order: 35)
      ]
    end

    def plugin_tabs
      self.class.tabs_for(repository: @repository, user: @user).map do |plugin_tab|
        plugin_tab.merge(key: plugin_tab[:id])
      end
    end

    def tab(id:, label:, path:, order:)
      {
        id: id,
        key: id,
        label: label,
        label_key: nil,
        path: path,
        paths: [ path ],
        component: nil,
        order: order,
        badge: nil
      }
    end
  end
end
