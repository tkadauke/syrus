module CredentialStore
  module ManagementScope
    class TeamScope < Base
      def can_manage?(user, scope_id)
        Team.find_by(id: scope_id)&.owned_by?(user) || false
      end

      def label(scope_id)
        Team.find_by(id: scope_id)&.name
      end

      def labels_for(scope_ids)
        Team.where(id: scope_ids).pluck(:id, :name).to_h
      end
    end
  end
end
