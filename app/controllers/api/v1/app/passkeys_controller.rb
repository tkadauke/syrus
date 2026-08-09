module Api
  module V1
    module App
      class PasskeysController < BaseController
        skip_before_action :require_authentication, only: %i[authentication_options authenticate]

        rate_limit to: 10, within: 3.minutes,
                   only: %i[registration_options authentication_options],
                   with: -> { render_error("rate_limited", "Try again later.", status: :too_many_requests) }

        def registration_options
          options = WebAuthn::Credential.options_for_create(
            user: {
              id: current_user.webauthn_id,
              name: current_user.email_address,
              display_name: current_user.name.presence || current_user.email_address
            },
            exclude: current_user.passkeys.pluck(:external_id).map { |id| { id: id, type: "public-key" } },
            authenticator_selection: { resident_key: "required", user_verification: "preferred" }
          )

          PasskeyChallenge.create_for!(type: "registration", challenge: options.challenge, user: current_user)

          render json: options.as_json
        end

        def register
          challenge = PasskeyChallenge.valid.for_type("registration").find_by(user: current_user)
          return render_error("no_challenge", "No pending registration challenge.", status: :unprocessable_content) unless challenge

          credential = WebAuthn::Credential.from_create(params.require(:credential).to_unsafe_h)
          credential.verify(challenge.challenge)

          passkey = current_user.passkeys.create!(
            external_id: credential.id,
            public_key: credential.public_key,
            sign_count: credential.sign_count,
            nickname: params[:nickname]&.strip.presence
          )

          challenge.destroy

          render json: passkey_json(passkey), status: :created
        rescue WebAuthn::Error => e
          render_error("webauthn_error", e.message, status: :unprocessable_content)
        end

        def authentication_options
          options = WebAuthn::Credential.options_for_get(
            allow: [],
            user_verification: "preferred"
          )

          PasskeyChallenge.create_for!(type: "authentication", challenge: options.challenge)

          render json: options.as_json
        end

        def authenticate
          challenge = PasskeyChallenge.valid.for_type("authentication").find_by(challenge: params[:challenge])
          return render_error("invalid_credential", "Invalid credential.", status: :unprocessable_content) unless challenge

          credential = WebAuthn::Credential.from_get(params.require(:credential).to_unsafe_h)
          passkey = Passkey.find_by(external_id: credential.id)
          return render_error("invalid_credential", "Invalid credential.", status: :unprocessable_content) unless passkey

          credential.verify(
            challenge.challenge,
            public_key: passkey.public_key,
            sign_count: passkey.sign_count
          )

          passkey.update!(sign_count: credential.sign_count, last_used_at: Time.current)
          challenge.destroy
          start_new_session_for(passkey.user)
          render json: { redirect_to: after_authentication_path }
        rescue WebAuthn::Error => e
          render_error("webauthn_error", e.message, status: :unprocessable_content)
        end

        private

        def current_user
          Current.user
        end

        def passkey_json(passkey)
          {
            id: passkey.id,
            nickname: passkey.nickname,
            created_at: passkey.created_at
          }
        end
      end
    end
  end
end
