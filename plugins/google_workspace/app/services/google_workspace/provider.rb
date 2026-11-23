require "net/http"

module GoogleWorkspace
  class Provider < ConnectedAccounts::GenericOauth2Provider
    GOOGLE_CALENDAR_SCOPE = "https://www.googleapis.com/auth/calendar.readonly".freeze

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
        Array(scopes).map { |scope| scope.to_s == CALENDAR_SCOPE ? GOOGLE_CALENDAR_SCOPE : scope.to_s }
      end

      def normalize_tokens(tokens)
        value = tokens.stringify_keys
        granted = value["scope"].to_s.split
        if granted.include?(GOOGLE_CALENDAR_SCOPE)
          value["scope"] = ((granted - [ GOOGLE_CALENDAR_SCOPE ]) + [ CALENDAR_SCOPE ]).join(" ")
        end
        value
      end
    end
  end
end
