module ConnectedAccounts
  class GenericOauth2Provider
    class << self
      def authorization(context)
        config = context.configuration
        credentials = config.client_credentials
        query = {
          response_type: "code", client_id: credentials.fetch(:client_id), redirect_uri: context.redirect_uri,
          state: context.state, scope: context.requested_scopes.join(" "), code_challenge: context.code_challenge,
          code_challenge_method: context.code_challenge ? "S256" : nil
        }.compact
        { authorize_url: "#{config.authorize_url}?#{Rack::Utils.build_query(query)}" }
      end

      def exchange_code(context)
        token_request(context.configuration, grant_type: "authorization_code", code: context.code,
          redirect_uri: context.redirect_uri, code_verifier: context.code_verifier)
      end

      def refresh(context)
        refreshed = token_request(context.configuration, grant_type: "refresh_token", refresh_token: context.tokens.fetch("refresh_token"))
        context.tokens.symbolize_keys.merge(refreshed)
      end

      def revoke(context)
        return { revoked: false } if context.configuration.revoke_url.blank?
        token = context.tokens["refresh_token"] || context.tokens["access_token"]
        OauthHttp.post_form(context.configuration.revoke_url, client_fields(context.configuration).merge(token: token))
        { revoked: true }
      end

      def identity(context)
        return { label: context.configuration.display_name } if context.configuration.identity_url.blank?
        payload = OauthHttp.get_json(context.configuration.identity_url, context.access_token)
        { label: payload[:email] || payload[:name] || payload[:id] || context.configuration.display_name }
      end

      def validate(context)
        return { healthy: true, message: "token available" } if context.configuration.identity_url.blank?
        identity(context)
        { healthy: true, message: "ok" }
      rescue Problem => error
        raise if %w[rate_limited quota_exceeded].include?(error.code)
        { healthy: false, message: error.message }
      end

      private

      def token_request(config, fields)
        result = OauthHttp.post_form(config.token_url, client_fields(config).merge(fields))
        result[:expires_at] = (Time.current + result.delete(:expires_in).to_i).iso8601 if result[:expires_in]
        result
      end

      def client_fields(config)
        credentials = config.client_credentials
        { client_id: credentials.fetch(:client_id), client_secret: credentials.fetch(:client_secret) }
      end
    end
  end
end
