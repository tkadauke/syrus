module Filters
  module Chips
    module DesignDocs
      class OpenComments < Base
        filter_name "open_comments"
        label "Open comments"
        bucket :boolean
        operators :is_true, :is_false

        def apply
          subquery = ::DesignDocs::DesignDocThread.where(state: "open").select(:design_doc_id)
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
