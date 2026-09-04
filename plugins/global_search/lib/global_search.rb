require "global_search/version"
require "global_search/source"
require "global_search/engine"

module GlobalSearch
  def self.register!
    Syrus::PluginRegistry.register(
      name:            "global_search",
      display_name:    "Search",
      version:         GlobalSearch::VERSION,
      default_enabled: true,
      disableable:     true,
      category:        "tooling",
      description:     "Unified search across Jobs, Epics, chats and plugin-contributed types.",
      long_description: "Search indexes Jobs, Epics and chat messages into the FTS database and serves the unified search endpoint behind the app's search bar.\n\nOther plugins contribute their own result types through the `search:source` point, so a plugin that owns records worth finding can appear in the same results without core knowing about it.",
      homepage:        "https://github.com/tkadauke/syrus",
      icon_url:        "/plugin-icons/spqr_eagle.svg",
      author:          "Thomas Kadauke",
      # Offered to other plugins: "global_search:source". Whoever owns records worth
      # finding contributes a source; core does not need to know the type list.
      hosts:           [ :source ],
      # The route keeps using core's `common` i18n namespace: its strings are
      # shared UI vocabulary ("search", "loading"), not search-specific, and a
      # plugin reading a core namespace is not a boundary violation.
      frontend: {
        routes: { "global_search/Search" => "app/frontend/routes/Search.tsx" }
      },
      routes: [
        { verb: "GET", path: "/api/v1/app/search", controller: "api/v1/app/search#index" }
      ],
      provides: {
        domain_subscriber: GlobalSearch::Subscribers,
        sidebar_page:      GlobalSearch::SidebarPages
      }
    )
  end

  def self.enabled?
    Syrus::PluginRegistry.all_plugins.any? { |manifest| manifest.name == "global_search" && manifest.enabled? }
  end
end
