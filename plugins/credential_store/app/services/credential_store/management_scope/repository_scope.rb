module CredentialStore
  module ManagementScope
    class RepositoryScope < Base
      def can_manage?(user, scope_id)
        repository = Syrus::Host::RepositoryRecord.find_by(id: scope_id)
        repository&.member_at_least?(user, "admin") || false
      end

      def label(scope_id)
        Syrus::Host::RepositoryRecord.find_by(id: scope_id)&.slug
      end

      def labels_for(scope_ids)
        Syrus::Host::RepositoryRecord.where(id: scope_ids).index_by(&:id).transform_values(&:slug)
      end
    end
  end
end
