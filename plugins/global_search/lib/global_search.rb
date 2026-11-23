require "global_search/source"

module GlobalSearch
  extend Syrus::PluginApi

  syrus_plugin "global_search" do
    experimental false
    requires_syrus nil
    display_name "Search"
    description "Unified search across Jobs, Epics, chats and plugin-contributed types."
    long_description "Search indexes Jobs, Epics and chat messages into the FTS database and serves the unified search endpoint behind the app's search bar.\n\nOther plugins contribute their own result types through the `global_search:source` point, so a plugin that owns records worth finding can appear in the same results without core knowing about it."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/global_search.svg"
    author "Thomas Kadauke"
    category "collaboration"
    default_enabled true
    disableable true
    hosts [ :source ]
    lifecycle callback_providers: "GlobalSearch::Callbacks",
              domain_subscribers: "GlobalSearch::Subscribers"
    provides sidebar_pages: "GlobalSearch::SidebarPages",
             "global_search:source" => [
               "GlobalSearch::JobSource",
               "GlobalSearch::EpicSource",
               "GlobalSearch::JobSearchSource",
               "GlobalSearch::EpicSearchSource",
               "GlobalSearch::SourceProvider"
             ]
    surface filter_subjects: { repository: { model: "Repository", chips: {
      "created_at" => "Filters::Chips::CreatedAt", "updated_at" => "Filters::Chips::UpdatedAt"
    } } }
    cli_commands [
      {
        path: %w[search], summary: "Search Jobs, Epics, chats, and repositories", handler: "GlobalSearch::Cli::Search",
        arguments: [ { name: "query", type: :string, required: true } ],
        flags: [
          { name: "type", type: :string },
          { name: "limit", type: :integer },
          { name: "json", type: :boolean, default: false }
        ]
      }
    ]
    route :get, "/api/v1/app/search", to: "api/v1/app/search#index"
    frontend routes: { "global_search/Search" => "app/frontend/routes/Search.tsx" },
        i18n: [ "app/frontend/i18n/locales/*/global_search.json" ]
  end
end
