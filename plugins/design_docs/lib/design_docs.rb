require "design_docs/data_cleanup"

module DesignDocs
  extend Syrus::PluginApi

  syrus_plugin "design_docs" do
    display_name "Design Docs"
    description "First-party collaborative Markdown design documents with repository links, versions, comments, and suggestions."
    long_description "Design Docs adds database-backed collaborative Markdown documents to Syrus. Documents have canonical DOC identifiers, auditable versions, repository associations, explicit collaborators for private drafts, inline discussion anchors, and owner-reviewed suggestions.\n\nThis is first-party authoring data, separate from attachment-oriented repository and job Documents."
    homepage "https://github.com/tkadauke/syrus"
    author "Thomas Kadauke"
    icon_url "/plugin-icons/design_docs.svg"
    category "collaboration"
    default_enabled true
    disableable true
    provides sidebar_page: "DesignDocs::SidebarPages",
             repo_page_tab: "DesignDocs::RepoPageTabs",
             workspace_tab: "DesignDocs::WorkspaceTabs",
             chat_mcp_tool_set: "DesignDocs::ChatToolSet",
             mcp_tool_set: "DesignDocs::WorkflowToolSet"
    route :get, "/api/v1/app/design_docs", to: "api/v1/app/design_docs#index"
    route :post, "/api/v1/app/design_docs", to: "api/v1/app/design_docs#create"
    route :get, "/api/v1/app/design_docs/:id", to: "api/v1/app/design_docs#show"
    route :patch, "/api/v1/app/design_docs/:id", to: "api/v1/app/design_docs#update"
    route :put, "/api/v1/app/design_docs/:id", to: "api/v1/app/design_docs#update"
    route :get, "/api/v1/app/design_docs/:id/versions", to: "api/v1/app/design_docs#versions"
    route :get, "/api/v1/app/design_docs/:id/versions/:version_id/threads", to: "api/v1/app/design_docs#version_threads"
    route :post, "/api/v1/app/design_docs/:id/comments", to: "api/v1/app/design_docs#comments"
    route :post, "/api/v1/app/design_docs/:id/suggestions", to: "api/v1/app/design_docs#create_suggestion"
    route :post, "/api/v1/app/design_docs/:id/threads/:thread_id/resolve", to: "api/v1/app/design_docs#resolve_thread"
    route :post, "/api/v1/app/design_docs/:id/suggestions/:suggestion_id/accept", to: "api/v1/app/design_docs#accept_suggestion"
    route :post, "/api/v1/app/design_docs/:id/suggestions/:suggestion_id/reject", to: "api/v1/app/design_docs#reject_suggestion"
    route :get, "/api/v1/app/repositories/:repository_id/design_docs", to: "api/v1/app/design_docs#repository_index"
    frontend routes: {
          "design_docs/DesignDocs" => "app/frontend/routes/DesignDocs.tsx"
        },
        repo_tabs: {
          "design_docs/RepositoryDesignDocs" => "app/frontend/repo_tabs/RepositoryDesignDocs.tsx"
        },
        workspace_tabs: {
          "design_docs/WorkspaceDesignDocs" => "app/frontend/workspaceTabs/WorkspaceDesignDocs.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/design_docs.json" ]

    # Rows this plugin owns on core records outlive it being disabled, and
    # still have to go when their owner does.
    always do |scope|
      DesignDocs::DataCleanup.install_into(scope)
    end

    while_enabled do |scope|
      DesignDocs::SmartFolders.install_into(scope)
    end
  end
end
