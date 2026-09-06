module Terminal
  module SidebarPages
    def self.sidebar_pages
      [
        {
          id: "terminal",
          label: "Terminal",
          label_key: "nav:terminal",
          path: "/terminal",
          # `paths` is the declaration both sides derive from -- React
          # registers a route per entry and PluginRouteResolver answers Rails'
          # SPA wildcard from the same list. Declaring only `path` contributes
          # nothing to either, so /terminal reached the page purely because
          # core hand-wrote a route for it.
          paths: [ "/terminal" ],
          component: "terminal/Terminal",
          icon: "terminal",
          # Core polls this and badges the nav entry with the number of open
          # sessions; it does not need to know that is what it is counting.
          badge_api_path: "/api/v1/app/terminal_sessions/open_count",
          order: 40
        }
      ]
    end
  end
end
