require "global_search/source"

module GlobalSearch
  extend Syrus::PluginApi

  syrus_plugin "global_search" do
    display_name "Search"
    description "Unified search across Jobs, Epics, chats and plugin-contributed types."
    long_description "Search indexes Jobs, Epics and chat messages into the FTS database and serves the unified search endpoint behind the app's search bar.\n\nOther plugins contribute their own result types through the `search:source` point, so a plugin that owns records worth finding can appear in the same results without core knowing about it."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/global_search.svg"
    author "Thomas Kadauke"
    category "collaboration"
    default_enabled true
    disableable true
    hosts [ :source ]
    provides domain_subscriber: "GlobalSearch::Subscribers",
             sidebar_page: "GlobalSearch::SidebarPages"
    route :get, "/api/v1/app/search", to: "api/v1/app/search#index"
    frontend routes: { "global_search/Search" => "app/frontend/routes/Search.tsx" }
  end
end
