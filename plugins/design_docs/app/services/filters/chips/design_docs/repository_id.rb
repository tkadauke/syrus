module Filters
  module Chips
    module DesignDocs
      class RepositoryId < Base
        filter_name "repository_id"
        label "Repository"
        bucket :fk
        operators :is, :is_not, :is_one_of, :is_none_of

        def apply
          ids = Array(value).compact_blank
          case op
          when :is
            with_repository([ value ])
          when :is_not
            without_repository([ value ])
          when :is_one_of
            with_repository(ids)
          when :is_none_of
            without_repository(ids)
          else
            unsupported_op!
          end
        end

        private

        def with_repository(ids)
          scope.joins(:design_doc_repositories).where(design_doc_repositories: { repository_id: ids }).distinct
        end

        def without_repository(ids)
          scope.where.not(id: scope.joins(:design_doc_repositories).where(design_doc_repositories: { repository_id: ids }).select(:id))
        end
      end
    end
  end
end
