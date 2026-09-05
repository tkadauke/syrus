module Syrus
  module Plugin
    # Marker interface for a plugin that suggests setting up its own feature on
    # a repository.
    #
    # App::RepositoryFeatureRecommendations is a fixed list of private methods
    # in core, so a recommendation for a plugin's feature meant core reaching
    # into that plugin's models -- which breaks the moment the plugin is
    # extracted or disabled.
    #
    #   def self.repository_recommendations(repository:, user:)
    #     [ { id: "scheduled_coverage", title: "...", body: "...", tone: "gray",
    #         category: "maintenance", order: 90,
    #         cta: { label: "Create schedule", kind: "link", path: "...", method: "GET" },
    #         secondary_path: "..." } ]
    #   end
    #
    # Return [] to suggest nothing. Core supplies the dismissal key and applies
    # its own cap, so a plugin cannot crowd out the built-ins; a provider that
    # raises is skipped rather than taking the repository page down.
    module RepositoryRecommendation
      def self.included(base) = base.extend(self)

      def repository_recommendations(repository:, user: nil) = []
    end
  end
end
