module AppApi
  class PublicAuthState
    def initialize(user:, invitation_token:)
      @user = user
      @invitation_token = invitation_token.to_s.presence
    end

    def as_json(*)
      {
        authenticated: user.present?,
        first_signup: first_signup?,
        signups_open: AppSetting.signups_open?,
        valid_invitation: valid_invitation?,
        cta: cta_payload
      }
    end

    private

    attr_reader :user, :invitation_token

    def cta_payload
      if user.present?
        { kind: "dashboard", label: "Open dashboard", href: "/dashboard/jobs?view=list" }
      elsif valid_invitation?
        { kind: "accept_invitation", label: "Accept invitation", href: signup_href }
      elsif first_signup?
        { kind: "create_first_account", label: "Create first account", href: "/users/new" }
      elsif AppSetting.signups_open?
        { kind: "sign_up", label: "Create account", href: "/users/new" }
      else
        { kind: "sign_in", label: "Sign in", href: "/session/new" }
      end
    end

    def first_signup?
      @first_signup ||= User.count.zero?
    end

    def valid_invitation?
      invitation&.usable? || false
    end

    def invitation
      return nil unless invitation_token

      @invitation ||= Invitation.find_by(token: invitation_token)
    end

    def signup_href
      return "/users/new" unless valid_invitation?

      "/users/new?token=#{CGI.escape(invitation_token)}"
    end
  end
end
