module Api
  module V1
    module App
      class AuthController < BaseController
        skip_before_action :require_authentication

        def status
          resume_session

          render json: AppApi::PublicAuthState.new(
            user: Current.user,
            invitation_token: params[:token]
          ).as_json
        end

        def signup
          invitation = invitation_from_params
          render json: {
            allowed: signup_allowed?(invitation),
            first_signup: User.count.zero?,
            signups_open: AppSetting.signups_open?,
            invitation: invitation&.usable? ? invitation_payload(invitation) : nil
          }
        end

        def create_session
          credentials = params.permit(:email_address, :password)
          user = User.authenticate_by(credentials)

          if user
            start_new_session_for(user)
            render json: { redirect_to: after_authentication_path }
          else
            render_error("invalid_credentials", I18n.t("api.auth.invalid_credentials"), status: :unprocessable_content)
          end
        end

        def create_user
          invitation = invitation_from_user_params
          return render_signup_forbidden unless signup_allowed?(invitation)

          user = User.new(user_params.except(:invitation_token))
          if user.save
            invitation&.accept!
            start_new_session_for(user)
            render json: { redirect_to: after_authentication_path, message: signup_notice(user) }, status: :created
          else
            render_error("validation_failed", user.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        def create_password
          if user = User.find_by(email_address: params[:email_address])
            PasswordsMailer.reset(user).deliver_later
          end

          render json: {
            message: I18n.t("api.auth.password_reset_sent"),
            redirect_to: new_session_path
          }
        end

        def update_password
          user = User.find_by_password_reset_token!(params[:token])
          if user.update(params.permit(:password, :password_confirmation))
            user.sessions.destroy_all
            render json: { message: I18n.t("api.auth.password_reset_success"), redirect_to: new_session_path }
          else
            render_error("validation_failed", user.errors.full_messages.to_sentence.presence || I18n.t("api.auth.password_mismatch"), status: :unprocessable_content)
          end
        rescue ActiveSupport::MessageVerifier::InvalidSignature
          render_error("invalid_token", I18n.t("api.auth.token_invalid"), status: :unprocessable_content)
        end

        private

        def user_params
          params.expect(user: [ :email_address, :password, :password_confirmation, :invitation_token ])
        end

        def invitation_from_params
          token = params[:token].to_s.presence
          return unless token

          Invitation.find_by(token: token)
        end

        def invitation_from_user_params
          token = user_params[:invitation_token].to_s.presence
          return unless token

          Invitation.find_by(token: token)
        end

        def signup_allowed?(invitation)
          invitation&.usable? || User.count.zero? || AppSetting.signups_open?
        end

        def render_signup_forbidden
          render_error("signup_closed", I18n.t("api.auth.signup_closed"), status: :forbidden)
        end

        def signup_notice(user)
          return I18n.t("api.auth.welcome_admin") if user.admin?

          I18n.t("api.auth.welcome")
        end

        def invitation_payload(invitation)
          {
            token: invitation.token,
            email_address: invitation.email_address,
            invited_by_email: invitation.invited_by.email_address
          }
        end
      end
    end
  end
end
