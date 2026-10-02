module CredentialStore
  module ManagementScope
    class TeamScope < Base
      def can_manage?(user, scope_id)
        Team.find_by(id: scope_id)&.owned_by?(user) || false
      end

      def label(scope_id)
        Team.find_by(id: scope_id)&.name
      end
    end
  end
end
