module CredentialStore
  module CredentialScope
    class RepositoryScope < Base
      def validate!(credential)
        require_scope_id!(credential)
        require_existing_record!(credential)
      end

      def usable_by?(credential, context)
        repository_id = credential.scope_id.to_i
        return false unless context.user
        return false unless context.allowed_repository_ids.include?(repository_id)
        return true if context.user.admin?
        return true if context.repository&.user_id == context.user.id && context.repository&.id == repository_id

        RepositoryMembership.where(repository_id: repository_id, user: context.user).exists? ||
          TeamRepository.where(repository_id: repository_id, team_id: TeamMembership.where(user: context.user).select(:team_id)).exists?
      end

      private

      def model_class = ::Repository
    end
  end
end
