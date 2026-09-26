module Filters
  module Chips
    module AdminInvitations
      class Inviter < Base
        filter_name "inviter"
        label "Inviter"
        bucket :string
        operators :contains

        def apply
          scope.where("#{users_table}.#{email_column} LIKE ? ESCAPE #{like_escape_sql}", "%#{escape_like(value)}%")
        end

        private

        def users_table = scope.connection.quote_table_name(User.table_name)
        def email_column = scope.connection.quote_column_name(:email_address)
      end
    end
  end
end
