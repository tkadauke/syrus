module PendingActions
  class PermissionManagement < Base
    def authorize_execution!
      # Management authority is deliberately independent from effect authority:
      # this action may only manage the confirming user's own permission store.
      management
    end

    def presentation_detail
      [ payload["capability"], payload["operation"], payload["rationale"] ].compact.join(" · ")
    end

    private

    def management = Permissions::Management.new(user)
  end
end
