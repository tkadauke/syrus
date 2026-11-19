require "net/http"

module ConnectedAccounts
  class GenericOauth2Provider
    class << self
      attr_writer :http

      def connect_scope_keys = Array(config!.scope_catalog).map(&:to_s)

      def authorization(context)
        config = config!
        challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(context.code_verifier), padding: false)
        query = URI.encode_www_form(response_type: "code", client_id: config.client_id, redirect_uri: context.redirect_uri,
          state: context.state, scope: context.requested_scopes.join(" "), code_challenge: challenge, code_challenge_method: "S256")
        { authorize_url: "#{config.authorize_url}?#{query}" }
      end

      def exchange_code(context)
        token_request(grant_type: "authorization_code", code: context.code, redirect_uri: context.redirect_uri, code_verifier: context.code_verifier)
      end

      def refresh(context)
        refresh_token = context.tokens["refresh_token"] || context.tokens[:refresh_token]
        raise Provider::PermanentError, "refresh authorization is unavailable" if refresh_token.blank?
        context.tokens.stringify_keys.merge(token_request(grant_type: "refresh_token", refresh_token: refresh_token))
      end

      def revoke(context)
        config = config!
        return { revoked: false } if config.revoke_url.blank?
        response = post_form(config.revoke_url, token: context.tokens["refresh_token"] || context.tokens["access_token"])
        raise_for_response!(response)
        { revoked: true }
      end

      def identity(context) = get_json(config!.identity_url, context.access_token)

      def validate(context)
        return { healthy: true, message: "validation endpoint not configured" } if config!.validate_url.blank?
        get_json(config!.validate_url, context.access_token).symbolize_keys
      end

      private

      def config! = ProviderConfig.find_by!(provider_key: "generic_oauth2")

      def token_request(**params)
        config = config!
        response = post_form(config.token_url, **params, client_id: config.client_id, client_secret: config.client_secret)
        raise_for_response!(response)
        JSON.parse(response.body).tap { |value| raise Provider::PermanentError, "provider returned no access token" if value["access_token"].blank? }
      rescue JSON::ParserError
        raise Provider::TransientError, "provider returned an invalid response"
      end

      def post_form(url, **params)
        request = Net::HTTP::Post.new(URI(url)); request.set_form_data(params)
        (@http || Net::HTTP).start(request.uri.hostname, request.uri.port, use_ssl: true) { |client| client.request(request) }
      rescue Timeout::Error, SocketError, SystemCallError
        raise Provider::TransientError, "provider is temporarily unavailable"
      end

      def get_json(url, token)
        request = Net::HTTP::Get.new(URI(url)); request["Authorization"] = "Bearer #{token}"
        response = (@http || Net::HTTP).start(request.uri.hostname, request.uri.port, use_ssl: true) { |client| client.request(request) }
        raise_for_response!(response)
        JSON.parse(response.body)
      rescue JSON::ParserError
        raise Provider::TransientError, "provider returned an invalid response"
      end

      def raise_for_response!(response)
        return if response.is_a?(Net::HTTPSuccess)
        error = [ 400, 401, 403 ].include?(response.code.to_i) ? Provider::PermanentError : Provider::TransientError
        raise error, "provider request failed (HTTP #{response.code})"
      end
    end
  end
end
