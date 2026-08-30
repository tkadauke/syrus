module Filters
  module Chips
    module DesignDocs
      class PendingSuggestions < Base
        filter_name "pending_suggestions"
        label "Pending suggestions"
        bucket :boolean
        operators :is_true, :is_false

        def apply
          matching = ::DesignDocs::DesignDocSuggestion.where(state: "pending").select(:design_doc_id)
          case op
          when :is_true then scope.where(id: matching)
          when :is_false then scope.where.not(id: matching)
          else unsupported_op!
          end
        end
      end
    end
  end
end
