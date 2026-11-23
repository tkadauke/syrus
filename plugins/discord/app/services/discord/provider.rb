module Discord
  # Connected-accounts provider for the Discord bot token, and the only place
  # that token is ever handled in the clear.
  #
  # Discord bot tokens are not OAuth: the `authorization` capability describes
  # token entry, there is nothing to exchange or refresh, and Discord offers no
  # revocation endpoint (a token is reset from the developer portal), so
  # `revoke` is a no-op. Operators connect the token on the instance-owned
  # connected accounts page.
  #
  # Platform services reach the token only through `system_invoke`, which the
  # broker calls with block-scoped access under a lease. Every operation is
  # fixed here; callers choose an operation name and plain-data input, never
  # code that receives the token.
  class Provider
    extend ConnectedAccounts::SystemServiceProvider

    KEY = "discord_bot".freeze
    IDENTITY = "discord.platform".freeze
    SCOPE = "discord.bot".freeze
    # Discord's REST origin. It is the manifest-declared target constraint on
    # the stored credential. The Gateway's wss:// host is dialled by
    # GatewayClient itself under the lease the broker grants against this
    # origin (a URL-prefix constraint only models http(s)).
    API_ORIGIN = "https://discord.com/api/v10/".freeze

    OPERATIONS = {
      "validate" => :check,
      "send_dm" => :send_dm,
      "gateway_session" => :gateway_session
    }.freeze

    class_attribute :gateway_client_factory, instance_writer: false,
      default: ->(token:, stale_check:) { Discord::GatewayClient.new(token: token, stale_check: stale_check) }

    class << self
      def authorization(_context)
        { authorization_kind: "token", instructions: "Paste the bot token from the Discord developer portal." }
      end

      def exchange_code(_context)
        raise ConnectedAccounts::Provider::PermanentError, "Discord bot tokens do not use an authorization code"
      end

      # Bot tokens do not expire, so a refresh returns them unchanged.
      def refresh(context) = context.tokens

      def revoke(_context) = { revoked: true }

      def identity(context)
        { label: Discord::Client.new(token: context.access_token).current_user["username"].to_s }
      rescue Discord::Client::Unauthorized => error
        raise ConnectedAccounts::Provider::PermanentError, error.message
      rescue Discord::Client::Error, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError => error
        raise ConnectedAccounts::Provider::TransientError, error.class.name
      end

      def validate(context)
        identity(context)
        { healthy: true, message: "ok" }
      rescue ConnectedAccounts::Provider::PermanentError => error
        { healthy: false, message: error.message }
      end

      def system_invoke(context)
        operation = OPERATIONS[context.input[:operation].to_s]
        raise ArgumentError, "unsupported Discord operation" unless operation

        context.access.with_token { |token| perform(token, operation, context.input) }
      end

      # Runs one operation with a token the caller holds for the call only.
      # Also the legacy path while a token has not been migrated yet.
      def perform(token, operation, input)
        public_send(operation, token, input)
      end

      def check(token, _input)
        validate(ConnectedAccounts::Provider::ValidateContext.new(access_token: token))
      end

      def send_dm(token, input)
        Discord::Client.new(token: token).send_dm(user_id: input.fetch(:user_id), text: input.fetch(:text))
      end

      # One Gateway session. The token is held in memory for the connection's
      # lifetime only: it lives in the GatewayClient (sent in IDENTIFY/RESUME
      # frames) and is dropped when the session ends. `stale_check` is polled
      # on every heartbeat so a rotated or revoked credential ends the session
      # and the caller reconnects with whatever token is current.
      def gateway_session(token, input)
        client = gateway_client_factory.call(token: token, stale_check: input[:stale_check])
        client.run { |event| input.fetch(:on_event).call(event) }
        {
          run_outcome: client.run_outcome,
          fatal_close_code: client.fatal_close_code,
          fatal_close_reason: client.fatal_close_reason,
          reset_reconnect_backoff: client.reset_reconnect_backoff?
        }
      end
    end
  end
end
