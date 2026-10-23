module PendingActionGroups
  module Confirmations
    class Independent < Confirmation
      def confirm_all!(user: nil) = group.confirm_independently!(user: user)
    end
  end
end
