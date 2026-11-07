module CredentialStore
  module CredentialScope
    class RepositoryScope < Base
      def validate!(credential)
        require_scope_id!(credential)
        require_existing_record!(credential)
      end

      def resolution_precedence = 1

      private

      def visible_scope_ids(context)
        return [] unless context.user

        allowed_ids = context.allowed_repository_ids.map(&:to_i)
        return allowed_ids if context.user.admin?

        owned_id = context.repository&.id if context.repository&.user_id == context.user.id
        membership_ids = RepositoryMembership.where(repository_id: allowed_ids, user: context.user).pluck(:repository_id)
        team_ids = TeamMembership.where(user: context.user).select(:team_id)
        team_repository_ids = TeamRepository.where(repository_id: allowed_ids, team_id: team_ids).pluck(:repository_id)

        ([ owned_id ] + membership_ids + team_repository_ids).compact.uniq & allowed_ids
      end

      def model_class = ::Repository
    end
  end
end
