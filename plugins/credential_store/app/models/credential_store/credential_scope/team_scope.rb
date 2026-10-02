module CredentialStore
  module CredentialScope
    class TeamScope < Base
      def validate!(credential)
        require_scope_id!(credential)
        require_existing_record!(credential)
      end

      def usable_by?(credential, context)
        return false unless context.user
        return true if context.user.admin?

        TeamMembership.where(team_id: credential.scope_id, user: context.user).exists?
      end

      private

      def model_class = ::Team
    end
  end
end
