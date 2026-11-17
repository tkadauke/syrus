# frozen_string_literal: true

module DesignDocs
  module Cli
    class Show < Syrus::Plugin::CliCommandHandler
      def call(args:, flags:, user:)
        id = normalize_id(args.fetch(0))
        design_doc = DesignDocPolicy::Scope.new(user, DesignDoc)
          .resolve
          .includes(*DesignDoc.summary_associations)
          .find(id)
        self.class.text(render(design_doc))
      end

      private

      def normalize_id(value)
        value.to_s.strip.sub(/\ADOC-/i, "").presence || raise(ArgumentError, "design doc id is required")
      end

      def render(design_doc)
        repositories = design_doc.repositories.map(&:slug).join(",")
        lines = [
          "#{design_doc.display_id} · #{design_doc.title}",
          "State: #{design_doc.state}",
          "Visibility: #{design_doc.visibility}",
          "Owner: #{design_doc.owner_user&.display_name.presence || '-'}"
        ]
        lines << "Repositories: #{repositories}" if repositories.present?
        lines.concat([ "Updated: #{design_doc.updated_at.iso8601}", "", AnchorMarkers.strip(design_doc.markdown) ])
        lines.join("\n")
      end
    end
  end
end
