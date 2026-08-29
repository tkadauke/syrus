module DesignDocs
  class SidebarPages
    include Syrus::Plugin::SidebarPage

    def self.sidebar_pages
      [
        {
          id: "design_docs.index",
          label: "Design Docs",
          path: "/design_docs",
          paths: [ "/design_docs" ],
          component: "design_docs/DesignDocs",
          icon: "document",
          order: 38
        }
      ]
    end
  end
end
