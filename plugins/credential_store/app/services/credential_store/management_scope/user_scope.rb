module CredentialStore
  module ManagementScope
    class UserScope < Base
      def can_manage?(user, scope_id)
        scope_id.to_i == user.id
      end

      def label(scope_id)
        User.find_by(id: scope_id)&.display_name
      end
    end
  end
end
