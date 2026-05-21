module Filters
  module Chips
    module AdminUsers
      class Email < Base
        filter_name "email"
        label "Email"
        bucket :string
        operators :contains, :not_contains

        def apply
          case op
          when :contains
            scope.where("email_address LIKE ?", "%#{value}%")
          when :not_contains
            scope.where("email_address NOT LIKE ?", "%#{value}%")
          else
            unsupported_op!
          end
        end
      end
    end
  end
end
