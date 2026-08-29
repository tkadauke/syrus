require "design_docs/version"
require "design_docs/engine"

module DesignDocs
  def self.register!
    Syrus::PluginRegistry.register(
      name:            "design_docs",
      display_name:    "Design Docs",
      version:         DesignDocs::VERSION,
      default_enabled: true,
      disableable:     true,
      category:        "tooling",
      description:     "First-party collaborative Markdown design documents with repository links, versions, comments, and suggestions.",
      long_description: "Design Docs adds database-backed collaborative Markdown documents to Syrus. Documents have canonical DOC identifiers, auditable versions, repository associations, explicit collaborators for private drafts, inline discussion anchors, and owner-reviewed suggestions.\n\nThis is first-party authoring data, separate from attachment-oriented repository and job Documents.",
      homepage:        "https://github.com/tkadauke/syrus",
      author:          "Thomas Kadauke",
      frontend: {
        routes: {
          "design_docs/DesignDocs" => "app/frontend/routes/DesignDocs.tsx"
        },
        repo_tabs: {
          "design_docs/RepositoryDesignDocs" => "app/frontend/repo_tabs/RepositoryDesignDocs.tsx"
        },
        workspace_tabs: {
          "design_docs/WorkspaceDesignDocs" => "app/frontend/workspaceTabs/WorkspaceDesignDocs.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/design_docs.json" ]
      },
      provides: {
        sidebar_page:  DesignDocs::SidebarPages,
        repo_page_tab: DesignDocs::RepoPageTabs,
        workspace_tab: DesignDocs::WorkspaceTabs
      }
    )
  end

  def self.enabled?
    Syrus::PluginRegistry.all_plugins.any? { |manifest| manifest.name == "design_docs" && manifest.enabled? }
  end
end
