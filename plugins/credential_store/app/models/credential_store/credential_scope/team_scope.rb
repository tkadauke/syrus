module CredentialStore
  module CredentialScope
    class TeamScope < Base
      def validate!(credential)
        require_scope_id!(credential)
        require_existing_record!(credential)
      end

      def resolution_precedence = 2

      private

      def visible_scope_ids(context)
        return [] unless context.user
        return Team.ids if context.user.admin?

        TeamMembership.where(user: context.user).pluck(:team_id)
      end

      def model_class = ::Team
    end
  end
end
