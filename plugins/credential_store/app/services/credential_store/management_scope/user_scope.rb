module CredentialStore
  module ManagementScope
    class UserScope < Base
      def can_manage?(user, scope_id)
        scope_id.to_i == user.id
      end

      def label(scope_id)
        Syrus::Host::UserRecord.find_by(id: scope_id)&.display_name
      end

      def labels_for(scope_ids)
        Syrus::Host::UserRecord.where(id: scope_ids).index_by(&:id).transform_values(&:display_name)
      end
    end
  end
end
