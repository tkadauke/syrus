module CredentialStore
  module ManagementScope
    class RepositoryScope < Base
      def can_manage?(user, scope_id)
        repository = Repository.find_by(id: scope_id)
        repository&.member_at_least?(user, "admin") || false
      end

      def label(scope_id)
        Repository.find_by(id: scope_id)&.slug
      end
    end
  end
end
