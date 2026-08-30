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
          smart_folder_api_path: "/api/v1/app/design_docs",
          smart_folder_subject: DesignDocs::SmartFolders::SUBJECT,
          order: 38
        }
      ]
    end
  end
end
