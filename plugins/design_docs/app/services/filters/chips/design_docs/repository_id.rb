module Filters
  module Chips
    module DesignDocs
      class RepositoryId < Base
        filter_name "repository_id"
        label "Repository"
        bucket :fk
        operators :is, :is_not, :is_one_of, :is_none_of
        typeahead true

        def apply
          matching = ::DesignDocs::DesignDocRepository.where(repository_id: repository_ids).select(:design_doc_id)

          case op
          when :is, :is_one_of
            scope.where(id: matching)
          when :is_not, :is_none_of
            scope.where.not(id: matching)
          else
            unsupported_op!
          end
        end

        private

        def repository_ids
          Array(value).filter_map { |entry| Integer(entry, exception: false) }
        end
      end
    end
  end
end
