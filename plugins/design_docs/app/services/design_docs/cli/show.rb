# frozen_string_literal: true

module DesignDocs
  module Cli
    class Show < Syrus::Host::CliCommandHandler
      def call(args:, flags:, user:)
        id = DocRef.parse(args.fetch(0))
        design_doc = DesignDocPolicy::Scope.new(user, DesignDoc)
          .resolve
          .includes(:owner_user, :repositories)
          .find(id)

        lines = [
          "#{design_doc.display_id} · #{design_doc.title}",
          "State: #{design_doc.state}",
          "Visibility: #{design_doc.visibility}",
          "Owner: #{design_doc.owner_user&.display_name.presence || '-'}"
        ]
        repositories = design_doc.repositories.map(&:slug).join(",")
        lines << "Repositories: #{repositories}" if repositories.present?
        lines.concat([
          "Updated: #{design_doc.updated_at.iso8601}",
          "",
          AnchorMarkers.strip(design_doc.markdown)
        ])

        self.class.raw_text("#{lines.join("\n")}\n")
      end
    end
  end
end
