module DesignDocs
  class SidebarPages
    include Syrus::Plugin::SidebarPage

    def self.sidebar_pages
      [
        {
          id: "design_docs.index",
          label: "Design Docs",
          path: "/design_docs",
          # The detail path belongs here too. `paths` is what both sides
          # derive from -- React registers a route per entry, and
          # PluginRouteResolver answers Rails' SPA wildcard from the same
          # list -- so a page missing from it renders the bare bootstrap
          # shell on direct navigation. DesignDocs.tsx has always branched on
          # `params.id`; it simply never received the route.
          paths: [ "/design_docs", "/design_docs/:id" ],
          component: "design_docs/DesignDocs",
          icon: "document",
          smart_folder_api_path: "/api/v1/app/design_docs",
          smart_folder_subject: DesignDocs::SmartFolders::SUBJECT,
          order: 38
        }
      ]
    end
  end
end
