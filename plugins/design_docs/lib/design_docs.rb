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
      routes: [
        {
          verb: "GET",
          path: "/api/v1/app/design_docs",
          controller: "api/v1/app/design_docs#index"
        },
        {
          verb: "POST",
          path: "/api/v1/app/design_docs",
          controller: "api/v1/app/design_docs#create"
        },
        {
          verb: "GET",
          path: "/api/v1/app/design_docs/:id",
          controller: "api/v1/app/design_docs#show"
        },
        {
          verb: "PATCH",
          path: "/api/v1/app/design_docs/:id",
          controller: "api/v1/app/design_docs#update"
        },
        {
          verb: "PUT",
          path: "/api/v1/app/design_docs/:id",
          controller: "api/v1/app/design_docs#update"
        },
        {
          verb: "GET",
          path: "/api/v1/app/design_docs/:id/versions",
          controller: "api/v1/app/design_docs#versions"
        },
        {
          verb: "GET",
          path: "/api/v1/app/repositories/:repository_id/design_docs",
          controller: "api/v1/app/design_docs#repository_index"
        }
      ]
    )
  end

  def self.enabled?
    Syrus::PluginRegistry.all_plugins.any? { |manifest| manifest.name == "design_docs" && manifest.enabled? }
  end
end
