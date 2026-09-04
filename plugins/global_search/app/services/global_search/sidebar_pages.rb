module GlobalSearch
  # The search page has no nav entry of its own -- it is reached from the
  # search bar in the app chrome -- so it declares no icon and sits outside
  # both navs. It is registered here purely so the SPA route resolver can find
  # the component the plugin owns.
  class SidebarPages
    include Syrus::Plugin::SidebarPage

    def self.sidebar_pages
      [
        {
          id: "global_search.results",
          label: "Search",
          path: "/search",
          paths: [ "/search" ],
          component: "global_search/Search",
          section: "hidden",
          order: 100
        }
      ]
    end
  end
end
