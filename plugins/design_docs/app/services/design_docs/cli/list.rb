# frozen_string_literal: true

module DesignDocs
  module Cli
    class List < Syrus::Plugin::CliCommandHandler
      def call(args:, flags:, user:)
        scope = DesignDocPolicy::Scope.new(user, DesignDoc).resolve
          .includes(*DesignDoc.summary_associations)
          .newest_first
        if flags["repo"].present?
          owner, name = flags.fetch("repo").strip.split("/", 2)
          repository = Repository.accessible_to(user).find_by!(owner: owner, name: name)
          scope = scope.joins(:design_doc_repositories)
            .where(design_doc_repositories: { repository_id: repository.id })
        end

        rows = scope.map do |design_doc|
          [
            design_doc.display_id,
            design_doc.title,
            design_doc.state,
            design_doc.visibility,
            design_doc.owner_user&.display_name.presence || "-",
            design_doc.repositories.map(&:slug).join(",").presence || "-",
            design_doc.updated_at.iso8601
          ]
        end
        self.class.table(columns: %w[DOC TITLE STATE VISIBILITY OWNER REPOS UPDATED], rows: rows)
      end
    end
  end
end
