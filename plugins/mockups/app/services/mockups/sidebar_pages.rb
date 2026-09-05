module Mockups
  # The Mockups primary-nav entry and the pages behind it.
  class SidebarPages
    include Syrus::Plugin::SidebarPage

    COMPONENT = "mockups/MockupsPage".freeze

    def self.sidebar_pages
      [
        {
          id: "mockups.index",
          label: "Mockups",
          label_key: "mockups:nav_mockups",
          path: "/mockups",
          # The detail path is served by the same component, which opens the
          # selected mockup in the side panel rather than navigating away.
          paths: [ "/mockups", "/mockups/:id" ],
          component: COMPONENT,
          icon: "mockup",
          section: "primary",
          order: 35
        }
      ]
    end
  end
end
