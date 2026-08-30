module Filters
  module Chips
    module DesignDocs
      class PendingSuggestions < Base
        filter_name "pending_suggestions"
        label "Pending suggestions"
        bucket :boolean
        operators :is_true, :is_false

        def apply
          subquery = ::DesignDocs::DesignDocSuggestion.where(state: "pending").select(:design_doc_id)
          case op
          when :is_true
            scope.where(id: subquery)
          when :is_false
            scope.where.not(id: subquery)
          else
            unsupported_op!
          end
        end
      end
    end
  end
end
