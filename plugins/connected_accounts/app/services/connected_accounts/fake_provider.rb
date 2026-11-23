module ConnectedAccounts
  class FakeProvider
    class << self
      def authorization(context)
        query = Rack::Utils.build_query(
          redirect_uri: context.redirect_uri,
          state: context.state,
          scope: context.requested_scopes.join(" "),
          read_only: context.read_only
        )
        { authorize_url: "https://fake.example/authorize?#{query}" }
      end

      def exchange_code(context)
        { access_token: "fake-access-#{context.code}", refresh_token: "fake-refresh-#{context.code}", expires_in: 3600 }
      end

      def refresh(context)
        context.tokens.merge(access_token: "fake-access-refreshed", expires_in: 3600)
      end

      def revoke(context)
        { revoked: context.tokens.key?(:access_token) || context.tokens.key?("access_token") }
      end

      def identity(context)
        { label: "#{context.access_token}@fake.example" }
      end

      def validate(context)
        { healthy: context.access_token.present?, message: context.access_token.present? ? "ok" : "missing access token" }
      end

      def events(context)
        signature = context.headers["X-Fake-Signature"] || context.headers["x-fake-signature"]
        raise ArgumentError, "invalid fake event signature" unless signature == "valid"

        payload = JSON.parse(context.body)
        { event_id: payload.fetch("id"), event_type: payload.fetch("type"), data: payload.fetch("data", {}) }
      end

      def system_invoke(context)
        { authorization: context.access.authorization_header, input: context.input }
      end
    end
  end
end
