require "net/http"

module GoogleWorkspace
  class Provider < ConnectedAccounts::GenericOauth2Provider
    GOOGLE_CALENDAR_SCOPE = "https://www.googleapis.com/auth/calendar.readonly".freeze
    GOOGLE_MAIL_SCOPE = "https://www.googleapis.com/auth/gmail.readonly".freeze

    class << self
      def authorization(context)
        challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(context.code_verifier), padding: false)
        query = URI.encode_www_form(
          response_type: "code",
          client_id: config!.client_id,
          redirect_uri: context.redirect_uri,
          state: context.state,
          scope: oauth_scopes(context.requested_scopes).join(" "),
          code_challenge: challenge,
          code_challenge_method: "S256",
          access_type: "offline",
          prompt: "consent"
        )
        { authorize_url: "#{config!.authorize_url}?#{query}" }
      end

      def exchange_code(context) = normalize_tokens(super)
      def refresh(context) = normalize_tokens(super)

      def identity(context)
        payload = super
        { "label" => payload.fetch("id") }
      end

      def validate(context)
        identity(context)
        { healthy: true }
      rescue ConnectedAccounts::Provider::PermanentError
        { healthy: false, needs_reauth: true }
      end

      private

      def config! = ConnectedAccounts::ProviderConfig.find_by!(provider_key: "google_workspace")

      def oauth_scopes(scopes)
        Array(scopes).map do |scope|
          { CALENDAR_SCOPE => GOOGLE_CALENDAR_SCOPE, MAIL_SCOPE => GOOGLE_MAIL_SCOPE }.fetch(scope.to_s, scope.to_s)
        end
      end

      def normalize_tokens(tokens)
        value = tokens.stringify_keys
        granted = value["scope"].to_s.split
        normalized = granted.map { |scope| { GOOGLE_CALENDAR_SCOPE => CALENDAR_SCOPE, GOOGLE_MAIL_SCOPE => MAIL_SCOPE }.fetch(scope, scope) }
        value["scope"] = normalized.join(" ")
        value
      end
    end
  end
end
