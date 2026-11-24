module Repositories
  # Per-repo/per-user analogue of Admin::PluginPagesPayload: unlike admin
  # pages (instance-wide), a repo-page-tab provider computes visibility
  # per repository/user via .repo_page_tabs(repository:, user:).
  class PluginRepoTabsPayload
    def self.tabs_for(repository:, user:)
      core_tabs_for(repository) + plugin_tabs_for(repository: repository, user: user)
    end

    def self.plugin_tabs_for(repository:, user:)
      Syrus::Plugin::Surface.contributions(:repo_page_tabs)
        .flat_map { |provider| tabs_from_provider(provider, repository: repository, user: user) }
        .sort_by { |tab| [ tab[:order].to_i, tab[:label].to_s ] }
    end

    def self.core_tabs_for(repository)
      [
        core_tab(id: "overview", label: I18n.t("api.repositories.tabs.overview"), path: "/repositories/#{repository.id}", order: 0),
        core_tab(id: "cognitive_debt", label: I18n.t("api.repositories.tabs.cognitive_debt"), path: "/repositories/#{repository.id}/cognitive_debt", order: 2),
        core_tab(id: "target_graph", label: I18n.t("api.repositories.tabs.target_graph"), path: "/repositories/#{repository.id}/target_graph", order: 3),
        core_tab(id: "documents", label: I18n.t("api.repositories.tabs.documents"), path: "/repositories/#{repository.id}/documents", order: 4)
      ]
    end

    def self.core_tab(id:, label:, path:, order:, badge: nil)
      { id: id, key: id, label: label, label_key: nil, path: path, paths: [ path ], component: nil, order: order, badge: badge }
    end

    def self.tabs_from_provider(provider, repository:, user:)
      Syrus::PluginInvocation.value(Syrus::PluginInvocation.call(
        extension_point: :repo_page_tab, provider:, operation: :repo_page_tabs, on_decline: []
      ) do
        Array(provider.repo_page_tabs(repository: repository, user: user)).map { |tab| tab_payload(tab) }
      end)
    end

    def self.tab_payload(tab)
      tab = tab.to_h.symbolize_keys
      {
        id: tab.fetch(:id).to_s,
        key: tab.fetch(:id).to_s,
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
