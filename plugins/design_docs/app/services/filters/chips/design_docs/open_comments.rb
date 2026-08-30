module Filters
  module Chips
    module DesignDocs
      class OpenComments < Base
        filter_name "open_comments"
        label "Open comments"
        bucket :boolean
        operators :is_true, :is_false

        def apply
          matching = ::DesignDocs::DesignDocThread.where(state: "open").select(:design_doc_id)
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
