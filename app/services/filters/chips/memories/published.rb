module Filters
  module Chips
    module Memories
      class Published < Base
        filter_name "published"
        label "Published"
        bucket :boolean
        operators :is_true, :is_false

        def apply
          case op
          when :is_true then scope.where(published: true)
          when :is_false then scope.where(published: false)
          else unsupported_op!
          end
        end
      end
    end
  end
end
